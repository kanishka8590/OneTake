"""Core ML encoder/decoder exporter with 4-bit blockwise quantization and 35 MB size gate."""

from __future__ import annotations

import argparse
import math
import os
import shutil
from typing import Any

import torch
import torch.nn as nn
import torch.nn.functional as F


def _compute_relative_position_bucket(
    relative_position: torch.Tensor,
    bidirectional: bool = True,
    num_buckets: int = 32,
    max_distance: int = 128,
) -> torch.Tensor:
    ret = torch.zeros_like(relative_position, dtype=torch.long)
    n = -relative_position
    if bidirectional:
        num_buckets //= 2
        ret += (n < 0).to(torch.long) * num_buckets
        n = torch.abs(n)
    else:
        n = torch.maximum(n, torch.zeros_like(n))
    max_exact = num_buckets // 2
    is_small = n < max_exact
    val_if_large = max_exact + (
        torch.log(n.float().clamp(min=1e-6) / max_exact)
        / math.log(max_distance / max_exact)
        * (num_buckets - max_exact)
    ).to(torch.long)
    val_if_large = torch.minimum(val_if_large, torch.full_like(val_if_large, num_buckets - 1))
    return ret + torch.where(is_small, n.to(torch.long), val_if_large)


def _t5_attention_forward(
    attn_mod: nn.Module,
    hidden_states: torch.Tensor,
    key_value_states: torch.Tensor | None,
    mask: torch.Tensor | None,
    position_bias: torch.Tensor | None,
    rel_buckets: torch.Tensor | None,
) -> tuple[torch.Tensor, torch.Tensor | None]:
    n_heads = int(attn_mod.n_heads)
    d_kv = int(attn_mod.key_value_proj_dim)

    q = attn_mod.q(hidden_states).reshape(1, -1, n_heads, d_kv).transpose(1, 2)
    kv_src = hidden_states if key_value_states is None else key_value_states
    k = attn_mod.k(kv_src).reshape(1, -1, n_heads, d_kv).transpose(1, 2)
    v = attn_mod.v(kv_src).reshape(1, -1, n_heads, d_kv).transpose(1, 2)

    scores = torch.matmul(q, k.transpose(2, 3))
    if position_bias is None and attn_mod.has_relative_attention_bias and rel_buckets is not None:
        bias_vals = attn_mod.relative_attention_bias(rel_buckets)  # (q_len, k_len, H)
        position_bias = bias_vals.permute(2, 0, 1).unsqueeze(0)   # (1, H, q_len, k_len)

    if position_bias is not None:
        scores = scores + position_bias
    if mask is not None:
        scores = scores + mask

    probs = F.softmax(scores.float(), dim=-1).to(scores.dtype)
    ctx = torch.matmul(probs, v).transpose(1, 2).reshape(1, -1, n_heads * d_kv)
    return attn_mod.o(ctx), position_bias


class T5EncoderWrapper(nn.Module):
    """Pure-op T5 encoder wrapper avoiding HF dynamic masking ops for Core ML tracing."""

    def __init__(self, t5_model: Any) -> None:
        super().__init__()
        self.embed = t5_model.shared
        self.blocks = t5_model.encoder.block
        self.final_ln = t5_model.encoder.final_layer_norm
        pos = torch.arange(512).unsqueeze(0)
        rel = pos - pos.transpose(0, 1)
        self.register_buffer("rel_buckets", _compute_relative_position_bucket(rel, bidirectional=True).to(torch.int32))

    def forward(self, input_ids: torch.Tensor, attention_mask: torch.Tensor) -> torch.Tensor:
        x = self.embed(input_ids.to(torch.long))
        s = input_ids.size(1)
        enc_mask = (1.0 - attention_mask[:, None, None, :].float()) * (-1e9)
        rel_b = self.rel_buckets[:s, :s].to(torch.long)
        pos_bias: torch.Tensor | None = None
        for block in self.blocks:
            normed = block.layer[0].layer_norm(x)
            attn_out, pos_bias = _t5_attention_forward(
                block.layer[0].SelfAttention, normed, None, enc_mask, pos_bias, rel_b
            )
            x = x + attn_out
            x = block.layer[1](x)
        return self.final_ln(x)


class T5DecoderWrapper(nn.Module):
    """Pure-op T5 decoder + LM head wrapper without HF dynamic cache or new_ones ops."""

    def __init__(self, t5_model: Any) -> None:
        super().__init__()
        self.embed = t5_model.shared
        self.blocks = t5_model.decoder.block
        self.final_ln = t5_model.decoder.final_layer_norm
        self.lm_head = t5_model.lm_head
        self.model_dim = float(t5_model.config.d_model)
        # Only scale when embeddings are actually weight-tied (Flan-T5-Small stores untied lm_head)
        self.tie_word_embeddings = bool(
            getattr(t5_model.config, "tie_word_embeddings", False)
            and t5_model.shared.weight.data_ptr() == t5_model.lm_head.weight.data_ptr()
        )
        pos = torch.arange(96).unsqueeze(0)
        rel = pos - pos.transpose(0, 1)
        self.register_buffer("rel_buckets", _compute_relative_position_bucket(rel, bidirectional=False).to(torch.int32))
        causal = torch.triu(torch.full((1, 1, 96, 96), -1e9, dtype=torch.float32), diagonal=1)
        self.register_buffer("causal_mask", causal)

    def forward(
        self,
        decoder_input_ids: torch.Tensor,
        encoder_hidden_states: torch.Tensor,
        encoder_attention_mask: torch.Tensor,
    ) -> torch.Tensor:
        x = self.embed(decoder_input_ids.to(torch.long))
        k = decoder_input_ids.size(1)
        self_mask = self.causal_mask[:, :, :k, :k]
        enc_mask = (1.0 - encoder_attention_mask[:, None, None, :].float()) * (-1e9)
        rel_b = self.rel_buckets[:k, :k].to(torch.long)
        pos_bias: torch.Tensor | None = None

        for block in self.blocks:
            normed = block.layer[0].layer_norm(x)
            self_out, pos_bias = _t5_attention_forward(
                block.layer[0].SelfAttention, normed, None, self_mask, pos_bias, rel_b
            )
            x = x + self_out
            cross_normed = block.layer[1].layer_norm(x)
            cross_out, _ = _t5_attention_forward(
                block.layer[1].EncDecAttention, cross_normed, encoder_hidden_states, enc_mask, None, None
            )
            x = x + cross_out
            x = block.layer[2](x)

        seq_out = self.final_ln(x)
        if self.tie_word_embeddings:
            seq_out = seq_out * (self.model_dim ** -0.5)
        return self.lm_head(seq_out)


def _dir_size_bytes(path: str) -> int:
    total = 0
    for root, _, files in os.walk(path):
        for fname in files:
            total += os.path.getsize(os.path.join(root, fname))
    return total


def _quantize_4bit(mlmodel: Any, vocab_size: int | None = None) -> Any:
    """Compresses transformer blocks to INT4 (block_size=64) and embeddings/lm_head to 6-bit k-means."""
    import coremltools.optimize.coreml as cto

    lm_ops: list[str] = []
    if vocab_size is not None:
        main_fn = mlmodel._mil_program.functions.get("main")
        if main_fn is not None:
            lm_ops = [
                op.name
                for op in main_fn.operations
                if op.op_type == "linear" and len(op.outputs[0].shape) >= 1 and op.outputs[0].shape[-1] == vocab_size
            ]

    q4_cfg = cto.OpLinearQuantizerConfig(
        mode="linear_symmetric",
        dtype="int4",
        granularity="per_block",
        block_size=64,
        weight_threshold=512,
    )
    q4_opt = cto.OptimizationConfig(
        global_config=q4_cfg,
        op_type_configs={"gather": None},
        op_name_configs={name: None for name in lm_ops},
    )
    compressed = cto.linear_quantize_weights(mlmodel, config=q4_opt)

    try:
        pal6 = cto.OpPalettizerConfig(
            mode="kmeans",
            nbits=6,
            granularity="per_grouped_channel",
            group_size=64,
            weight_threshold=512,
        )
        p6_opt = cto.OptimizationConfig(
            global_config=None,
            op_type_configs={"gather": pal6},
            op_name_configs={name: pal6 for name in lm_ops},
        )
        return cto.palettize_weights(compressed, config=p6_opt)
    except Exception:
        pal6_uniform = cto.OpPalettizerConfig(
            mode="uniform",
            nbits=6,
            granularity="per_grouped_channel",
            group_size=64,
            weight_threshold=512,
        )
        p6_opt = cto.OptimizationConfig(
            global_config=None,
            op_type_configs={"gather": pal6_uniform},
            op_name_configs={name: pal6_uniform for name in lm_ops},
        )
        return cto.palettize_weights(compressed, config=p6_opt)


def _stamp_metadata(mlmodel: Any, author: str, description: str) -> None:
    mlmodel.author = author
    mlmodel.license = "OneTake Proprietary"
    mlmodel.short_description = description
    mlmodel.version = "2.0.0"


def export_coreml_models(
    checkpoint_dir: str,
    output_dir: str,
    sp_vocab_path: str | None = None,
    author: str = "Porage-Lover <jitund05@gmail.com>",
    max_total_mb: float = 35.0,
) -> dict[str, Any]:
    """Traces, converts, and 4-bit quantizes pruned Flan-T5-Small to Core ML."""
    import coremltools as ct
    from transformers import AutoModelForSeq2SeqLM

    os.makedirs(output_dir, exist_ok=True)
    model = AutoModelForSeq2SeqLM.from_pretrained(checkpoint_dir).eval().cpu()
    d_model = int(model.config.d_model)

    enc_wrap = T5EncoderWrapper(model).eval()
    dec_wrap = T5DecoderWrapper(model).eval()

    ex_enc_ids = torch.ones((1, 256), dtype=torch.int32)
    ex_enc_mask = torch.ones((1, 256), dtype=torch.int32)
    ex_hidden = enc_wrap(ex_enc_ids, ex_enc_mask)
    ex_dec_ids = torch.zeros((1, 16), dtype=torch.int32)

    with torch.no_grad():
        traced_enc = torch.jit.trace(enc_wrap, (ex_enc_ids, ex_enc_mask))
        traced_dec = torch.jit.trace(dec_wrap, (ex_dec_ids, ex_hidden, ex_enc_mask))
        check_hidden = traced_enc(ex_enc_ids, ex_enc_mask)
        check_logits = traced_dec(ex_dec_ids, check_hidden, ex_enc_mask)
        assert torch.isfinite(check_hidden).all(), "Encoder trace produced non-finite values"
        assert torch.isfinite(check_logits).all(), "Decoder trace produced non-finite values"

    s_dim = ct.RangeDim(lower_bound=1, upper_bound=512, default=256)
    k_dim = ct.RangeDim(lower_bound=1, upper_bound=96, default=16)

    # Use FLOAT32 compute precision so T5 attention masking (-3.4e38) and GeGLU/LayerNorm never overflow FP16 to NaN.
    # Weights remain 4-bit blockwise compressed on disk to fit the <= 35 MB bundle cap.
    enc_ml = ct.convert(
        traced_enc,
        source="pytorch",
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.iOS18,
        compute_precision=ct.precision.FLOAT32,
        inputs=[
            ct.TensorType(name="input_ids", shape=(1, s_dim), dtype=int),
            ct.TensorType(name="attention_mask", shape=(1, s_dim), dtype=int),
        ],
        outputs=[ct.TensorType(name="encoder_hidden_states")],
    )

    dec_ml = ct.convert(
        traced_dec,
        source="pytorch",
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.iOS18,
        compute_precision=ct.precision.FLOAT32,
        inputs=[
            ct.TensorType(name="decoder_input_ids", shape=(1, k_dim), dtype=int),
            ct.TensorType(name="encoder_hidden_states", shape=(1, s_dim, d_model)),
            ct.TensorType(name="encoder_attention_mask", shape=(1, s_dim), dtype=int),
        ],
        outputs=[ct.TensorType(name="logits")],
    )

    vocab_size = int(model.config.vocab_size)
    enc_q = _quantize_4bit(enc_ml, vocab_size=vocab_size)
    dec_q = _quantize_4bit(dec_ml, vocab_size=vocab_size)
    _stamp_metadata(enc_q, author, "OneTake Flan-T5-Small Pruned 4-bit Encoder")
    _stamp_metadata(dec_q, author, "OneTake Flan-T5-Small Pruned 4-bit Decoder")

    enc_path = os.path.join(output_dir, "OneTakeParserEncoder.mlpackage")
    dec_path = os.path.join(output_dir, "OneTakeParserDecoder.mlpackage")
    for p in (enc_path, dec_path):
        if os.path.exists(p):
            shutil.rmtree(p)
    enc_q.save(enc_path)
    dec_q.save(dec_path)

    artifacts = [enc_path, dec_path]

    # Attempt Multi-Function Core ML merge into OneTakeParserANE.mlpackage to deduplicate shared.weight
    ane_path = os.path.join(output_dir, "OneTakeParserANE.mlpackage")
    if os.path.exists(ane_path):
        shutil.rmtree(ane_path)
    multi_fn_used = False
    try:
        desc = ct.utils.MultiFunctionDescriptor()
        desc.add_function(enc_path, src_function_name="main", target_function_name="encode")
        desc.add_function(dec_path, src_function_name="main", target_function_name="decode")
        desc.default_function_name = "encode"
        ct.utils.save_multifunction(desc, ane_path)
        merged = ct.models.MLModel(ane_path, skip_model_load=True)
        _stamp_metadata(merged, author, "OneTake Flan-T5-Small Multi-Function ANE Parser (4-bit)")
        merged.save(ane_path)
        shutil.rmtree(enc_path)
        shutil.rmtree(dec_path)
        artifacts = [ane_path]
        multi_fn_used = True
    except Exception as exc:
        print(f"[OneTake] Multi-function merge fallback ({exc}); keeping Encoder + Decoder pair.")

    total_bytes = sum(_dir_size_bytes(p) for p in artifacts)
    if sp_vocab_path and os.path.exists(sp_vocab_path):
        total_bytes += os.path.getsize(sp_vocab_path)

    total_mb = total_bytes / (1024.0 * 1024.0)
    print(f"[OneTake] Exported artifacts={artifacts}, multi_function={multi_fn_used}, total_size={total_mb:.2f} MB")
    assert total_mb <= max_total_mb, f"Bundle size {total_mb:.2f} MB exceeded {max_total_mb} MB budget!"
    return {
        "artifacts": artifacts,
        "multi_function": multi_fn_used,
        "total_mb": round(total_mb, 2),
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--checkpoint-dir", required=True)
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--sp-vocab", default=None)
    parser.add_argument("--author", default="Porage-Lover <jitund05@gmail.com>")
    parser.add_argument("--max-mb", type=float, default=35.0)
    args = parser.parse_args()
    export_coreml_models(
        checkpoint_dir=args.checkpoint_dir,
        output_dir=args.output_dir,
        sp_vocab_path=args.sp_vocab,
        author=args.author,
        max_total_mb=args.max_mb,
    )
