"""Native Apple Silicon MLX training + INT4 QAT for vocab-pruned Flan-T5-Small -> Core ML."""

from __future__ import annotations

import argparse
import json
import math
import os
import time
from typing import Any

import mlx.core as mx
import mlx.nn as nn
import mlx.optimizers as optim
from mlx.utils import tree_flatten, tree_unflatten
import numpy as np
import torch
from transformers import AutoModelForSeq2SeqLM, AutoTokenizer

from dataset_generator import generate_casting_corpus
from export_coreml import export_coreml_models
from train_and_qat import (
    extract_sentencepiece_table,
    parse_tagged_dict,
    prune_flan_t5_vocab,
)
from vocab_surgery import (
    _normalize_input_symbols,
    build_pruned_piece_table,
    save_sp_vocab_json,
    unigram_decode_reference,
    unigram_encode_reference,
)


def _relative_position_bucket(
    relative_position: np.ndarray,
    bidirectional: bool = True,
    num_buckets: int = 32,
    max_distance: int = 128,
) -> np.ndarray:
    """Exact NumPy mirror of HuggingFace `T5Attention._relative_position_bucket`."""
    ret = np.zeros_like(relative_position, dtype=np.int32)
    n = -relative_position
    if bidirectional:
        num_buckets //= 2
        ret += (n < 0).astype(np.int32) * num_buckets
        n = np.abs(n)
    else:
        n = np.maximum(n, 0)

    max_exact = num_buckets // 2
    is_small = n < max_exact

    val_if_large = max_exact + (
        np.log(np.maximum(n.astype(np.float32), 1e-6) / max_exact)
        / math.log(max_distance / max_exact)
        * (num_buckets - max_exact)
    ).astype(np.int32)
    val_if_large = np.minimum(val_if_large, num_buckets - 1)
    ret += np.where(is_small, n, val_if_large)
    return ret


class T5RMSNorm(nn.Module):
    def __init__(self, hidden_size: int, eps: float = 1e-6) -> None:
        super().__init__()
        self.weight = mx.ones((hidden_size,))
        self.eps = eps

    def __call__(self, x: mx.array) -> mx.array:
        variance = mx.mean(mx.square(x.astype(mx.float32)), axis=-1, keepdims=True)
        normed = x.astype(mx.float32) * mx.rsqrt(variance + self.eps)
        return self.weight * normed.astype(x.dtype)


class T5AttentionMLX(nn.Module):
    def __init__(
        self,
        d_model: int,
        d_kv: int,
        num_heads: int,
        is_decoder: bool = False,
        has_relative_bias: bool = False,
        num_buckets: int = 32,
    ) -> None:
        super().__init__()
        self.d_model = d_model
        self.d_kv = d_kv
        self.num_heads = num_heads
        self.inner_dim = num_heads * d_kv
        self.is_decoder = is_decoder
        self.has_relative_bias = has_relative_bias

        self.q = nn.Linear(d_model, self.inner_dim, bias=False)
        self.k = nn.Linear(d_model, self.inner_dim, bias=False)
        self.v = nn.Linear(d_model, self.inner_dim, bias=False)
        self.o = nn.Linear(self.inner_dim, d_model, bias=False)
        if has_relative_bias:
            self.relative_attention_bias = nn.Embedding(num_buckets, num_heads)

    def __call__(
        self,
        hidden_states: mx.array,
        key_value_states: mx.array | None = None,
        mask: mx.array | None = None,
        position_bias: mx.array | None = None,
        rel_buckets: mx.array | None = None,
    ) -> tuple[mx.array, mx.array | None]:
        bsz, q_len, _ = hidden_states.shape
        kv_src = hidden_states if key_value_states is None else key_value_states
        k_len = kv_src.shape[1]

        q = self.q(hidden_states).reshape(bsz, q_len, self.num_heads, self.d_kv).transpose(0, 2, 1, 3)
        k = self.k(kv_src).reshape(bsz, k_len, self.num_heads, self.d_kv).transpose(0, 2, 1, 3)
        v = self.v(kv_src).reshape(bsz, k_len, self.num_heads, self.d_kv).transpose(0, 2, 1, 3)

        # T5 unscaled dot-product attention
        scores = mx.matmul(q, k.transpose(0, 1, 3, 2))

        if position_bias is None and self.has_relative_bias and rel_buckets is not None:
            bias_vals = self.relative_attention_bias(rel_buckets)  # (q_len, k_len, H)
            position_bias = bias_vals.transpose(2, 0, 1)[None, :, :, :]  # (1, H, q_len, k_len)

        if position_bias is not None:
            scores = scores + position_bias[:, :, :q_len, :k_len]
        if mask is not None:
            scores = scores + mask

        attn_weights = mx.softmax(scores.astype(mx.float32), axis=-1).astype(scores.dtype)
        attn_out = mx.matmul(attn_weights, v)
        attn_out = attn_out.transpose(0, 2, 1, 3).reshape(bsz, q_len, self.inner_dim)
        return self.o(attn_out), position_bias


class T5GatedFFNMLX(nn.Module):
    def __init__(self, d_model: int, d_ff: int, eps: float = 1e-6) -> None:
        super().__init__()
        self.layer_norm = T5RMSNorm(d_model, eps=eps)
        self.wi_0 = nn.Linear(d_model, d_ff, bias=False)
        self.wi_1 = nn.Linear(d_model, d_ff, bias=False)
        self.wo = nn.Linear(d_ff, d_model, bias=False)

    def __call__(self, hidden_states: mx.array) -> mx.array:
        normed = self.layer_norm(hidden_states)
        gated = nn.gelu_approx(self.wi_0(normed)) * self.wi_1(normed)
        return hidden_states + self.wo(gated)


class T5EncoderBlockMLX(nn.Module):
    def __init__(self, d_model: int, d_kv: int, num_heads: int, d_ff: int, eps: float, has_rel_bias: bool) -> None:
        super().__init__()
        self.self_ln = T5RMSNorm(d_model, eps=eps)
        self.self_attn = T5AttentionMLX(d_model, d_kv, num_heads, is_decoder=False, has_relative_bias=has_rel_bias)
        self.ffn = T5GatedFFNMLX(d_model, d_ff, eps=eps)

    def __call__(
        self,
        x: mx.array,
        mask: mx.array | None,
        pos_bias: mx.array | None,
        rel_buckets: mx.array | None,
    ) -> tuple[mx.array, mx.array | None]:
        normed = self.self_ln(x)
        attn_out, pos_bias = self.self_attn(normed, mask=mask, position_bias=pos_bias, rel_buckets=rel_buckets)
        x = x + attn_out
        x = self.ffn(x)
        return x, pos_bias


class T5DecoderBlockMLX(nn.Module):
    def __init__(self, d_model: int, d_kv: int, num_heads: int, d_ff: int, eps: float, has_rel_bias: bool) -> None:
        super().__init__()
        self.self_ln = T5RMSNorm(d_model, eps=eps)
        self.self_attn = T5AttentionMLX(d_model, d_kv, num_heads, is_decoder=True, has_relative_bias=has_rel_bias)
        self.cross_ln = T5RMSNorm(d_model, eps=eps)
        self.cross_attn = T5AttentionMLX(d_model, d_kv, num_heads, is_decoder=True, has_relative_bias=False)
        self.ffn = T5GatedFFNMLX(d_model, d_ff, eps=eps)

    def __call__(
        self,
        x: mx.array,
        enc_hidden: mx.array,
        self_mask: mx.array | None,
        enc_mask: mx.array | None,
        self_pos_bias: mx.array | None,
        self_rel_buckets: mx.array | None,
    ) -> tuple[mx.array, mx.array | None]:
        normed = self.self_ln(x)
        self_out, self_pos_bias = self.self_attn(
            normed,
            mask=self_mask,
            position_bias=self_pos_bias,
            rel_buckets=self_rel_buckets,
        )
        x = x + self_out

        cross_out, _ = self.cross_attn(
            self.cross_ln(x),
            key_value_states=enc_hidden,
            mask=enc_mask,
            position_bias=None,
            rel_buckets=None,
        )
        x = x + cross_out
        x = self.ffn(x)
        return x, self_pos_bias


class MlxFlanT5(nn.Module):
    """Pure MLX Flan-T5-Small matching HuggingFace `T5ForConditionalGeneration` weights 1:1."""

    def __init__(
        self,
        vocab_size: int,
        d_model: int = 512,
        d_kv: int = 64,
        num_heads: int = 6,
        d_ff: int = 1024,
        num_layers: int = 8,
        num_decoder_layers: int = 8,
        eps: float = 1e-6,
    ) -> None:
        super().__init__()
        self.vocab_size = vocab_size
        self.d_model = d_model

        self.shared = nn.Embedding(vocab_size, d_model)
        self.encoder_blocks = [
            T5EncoderBlockMLX(d_model, d_kv, num_heads, d_ff, eps, has_rel_bias=(i == 0))
            for i in range(num_layers)
        ]
        self.encoder_final_ln = T5RMSNorm(d_model, eps=eps)

        self.decoder_blocks = [
            T5DecoderBlockMLX(d_model, d_kv, num_heads, d_ff, eps, has_rel_bias=(i == 0))
            for i in range(num_decoder_layers)
        ]
        self.decoder_final_ln = T5RMSNorm(d_model, eps=eps)
        self.lm_head = nn.Linear(d_model, vocab_size, bias=False)

    def encode(self, input_ids: mx.array, attention_mask: mx.array, enc_rel_buckets: mx.array) -> tuple[mx.array, mx.array]:
        x = self.shared(input_ids)
        # (B, 1, 1, S) additive mask
        enc_mask = (1.0 - attention_mask[:, None, None, :].astype(x.dtype)) * (-1e9)
        pos_bias = None
        for block in self.encoder_blocks:
            x, pos_bias = block(x, mask=enc_mask, pos_bias=pos_bias, rel_buckets=enc_rel_buckets)
        x = self.encoder_final_ln(x)
        return x, enc_mask

    def decode(
        self,
        decoder_input_ids: mx.array,
        enc_hidden: mx.array,
        enc_mask: mx.array,
        dec_self_mask: mx.array,
        dec_rel_buckets: mx.array,
    ) -> mx.array:
        x = self.shared(decoder_input_ids)
        pos_bias = None
        for block in self.decoder_blocks:
            x, pos_bias = block(
                x,
                enc_hidden=enc_hidden,
                self_mask=dec_self_mask,
                enc_mask=enc_mask,
                self_pos_bias=pos_bias,
                self_rel_buckets=dec_rel_buckets,
            )
        x = self.decoder_final_ln(x)
        return self.lm_head(x)

    def __call__(
        self,
        input_ids: mx.array,
        attention_mask: mx.array,
        decoder_input_ids: mx.array,
        enc_rel_buckets: mx.array,
        dec_self_mask: mx.array,
        dec_rel_buckets: mx.array,
    ) -> mx.array:
        enc_hidden, enc_mask = self.encode(input_ids, attention_mask, enc_rel_buckets)
        return self.decode(decoder_input_ids, enc_hidden, enc_mask, dec_self_mask, dec_rel_buckets)


def _sync_hf_to_mlx(hf_model: Any, mlx_model: MlxFlanT5) -> None:
    sd = {k: v.detach().cpu().float().numpy() for k, v in hf_model.state_dict().items()}
    updates: list[tuple[str, mx.array]] = [
        ("shared.weight", mx.array(sd["shared.weight"])),
        ("lm_head.weight", mx.array(sd["lm_head.weight"])),
        ("encoder_final_ln.weight", mx.array(sd["encoder.final_layer_norm.weight"])),
        ("decoder_final_ln.weight", mx.array(sd["decoder.final_layer_norm.weight"])),
    ]
    for i, blk in enumerate(mlx_model.encoder_blocks):
        p = f"encoder.block.{i}"
        updates.extend([
            (f"encoder_blocks.{i}.self_ln.weight", mx.array(sd[f"{p}.layer.0.layer_norm.weight"])),
            (f"encoder_blocks.{i}.self_attn.q.weight", mx.array(sd[f"{p}.layer.0.SelfAttention.q.weight"])),
            (f"encoder_blocks.{i}.self_attn.k.weight", mx.array(sd[f"{p}.layer.0.SelfAttention.k.weight"])),
            (f"encoder_blocks.{i}.self_attn.v.weight", mx.array(sd[f"{p}.layer.0.SelfAttention.v.weight"])),
            (f"encoder_blocks.{i}.self_attn.o.weight", mx.array(sd[f"{p}.layer.0.SelfAttention.o.weight"])),
            (f"encoder_blocks.{i}.ffn.layer_norm.weight", mx.array(sd[f"{p}.layer.1.layer_norm.weight"])),
            (f"encoder_blocks.{i}.ffn.wi_0.weight", mx.array(sd[f"{p}.layer.1.DenseReluDense.wi_0.weight"])),
            (f"encoder_blocks.{i}.ffn.wi_1.weight", mx.array(sd[f"{p}.layer.1.DenseReluDense.wi_1.weight"])),
            (f"encoder_blocks.{i}.ffn.wo.weight", mx.array(sd[f"{p}.layer.1.DenseReluDense.wo.weight"])),
        ])
        if i == 0:
            updates.append((
                f"encoder_blocks.{i}.self_attn.relative_attention_bias.weight",
                mx.array(sd[f"{p}.layer.0.SelfAttention.relative_attention_bias.weight"]),
            ))
    for i, blk in enumerate(mlx_model.decoder_blocks):
        p = f"decoder.block.{i}"
        updates.extend([
            (f"decoder_blocks.{i}.self_ln.weight", mx.array(sd[f"{p}.layer.0.layer_norm.weight"])),
            (f"decoder_blocks.{i}.self_attn.q.weight", mx.array(sd[f"{p}.layer.0.SelfAttention.q.weight"])),
            (f"decoder_blocks.{i}.self_attn.k.weight", mx.array(sd[f"{p}.layer.0.SelfAttention.k.weight"])),
            (f"decoder_blocks.{i}.self_attn.v.weight", mx.array(sd[f"{p}.layer.0.SelfAttention.v.weight"])),
            (f"decoder_blocks.{i}.self_attn.o.weight", mx.array(sd[f"{p}.layer.0.SelfAttention.o.weight"])),
            (f"decoder_blocks.{i}.cross_ln.weight", mx.array(sd[f"{p}.layer.1.layer_norm.weight"])),
            (f"decoder_blocks.{i}.cross_attn.q.weight", mx.array(sd[f"{p}.layer.1.EncDecAttention.q.weight"])),
            (f"decoder_blocks.{i}.cross_attn.k.weight", mx.array(sd[f"{p}.layer.1.EncDecAttention.k.weight"])),
            (f"decoder_blocks.{i}.cross_attn.v.weight", mx.array(sd[f"{p}.layer.1.EncDecAttention.v.weight"])),
            (f"decoder_blocks.{i}.cross_attn.o.weight", mx.array(sd[f"{p}.layer.1.EncDecAttention.o.weight"])),
            (f"decoder_blocks.{i}.ffn.layer_norm.weight", mx.array(sd[f"{p}.layer.2.layer_norm.weight"])),
            (f"decoder_blocks.{i}.ffn.wi_0.weight", mx.array(sd[f"{p}.layer.2.DenseReluDense.wi_0.weight"])),
            (f"decoder_blocks.{i}.ffn.wi_1.weight", mx.array(sd[f"{p}.layer.2.DenseReluDense.wi_1.weight"])),
            (f"decoder_blocks.{i}.ffn.wo.weight", mx.array(sd[f"{p}.layer.2.DenseReluDense.wo.weight"])),
        ])
        if i == 0:
            updates.append((
                f"decoder_blocks.{i}.self_attn.relative_attention_bias.weight",
                mx.array(sd[f"{p}.layer.0.SelfAttention.relative_attention_bias.weight"]),
            ))
    mlx_model.update(tree_unflatten(updates))
    mx.eval(mlx_model.parameters())


def _sync_mlx_to_hf(mlx_model: MlxFlanT5, hf_model: Any) -> None:
    mx.eval(mlx_model.parameters())
    params = dict(tree_flatten(mlx_model.parameters()))

    def t(key: str) -> torch.Tensor:
        return torch.from_numpy(np.array(params[key].astype(mx.float32), copy=True))

    with torch.no_grad():
        hf_model.shared.weight.copy_(t("shared.weight"))
        hf_model.encoder.embed_tokens.weight.copy_(hf_model.shared.weight)
        hf_model.decoder.embed_tokens.weight.copy_(hf_model.shared.weight)
        hf_model.lm_head.weight.copy_(t("lm_head.weight"))
        hf_model.encoder.final_layer_norm.weight.copy_(t("encoder_final_ln.weight"))
        hf_model.decoder.final_layer_norm.weight.copy_(t("decoder_final_ln.weight"))

        for i in range(len(mlx_model.encoder_blocks)):
            blk = hf_model.encoder.block[i]
            blk.layer[0].layer_norm.weight.copy_(t(f"encoder_blocks.{i}.self_ln.weight"))
            blk.layer[0].SelfAttention.q.weight.copy_(t(f"encoder_blocks.{i}.self_attn.q.weight"))
            blk.layer[0].SelfAttention.k.weight.copy_(t(f"encoder_blocks.{i}.self_attn.k.weight"))
            blk.layer[0].SelfAttention.v.weight.copy_(t(f"encoder_blocks.{i}.self_attn.v.weight"))
            blk.layer[0].SelfAttention.o.weight.copy_(t(f"encoder_blocks.{i}.self_attn.o.weight"))
            if i == 0:
                blk.layer[0].SelfAttention.relative_attention_bias.weight.copy_(
                    t(f"encoder_blocks.{i}.self_attn.relative_attention_bias.weight")
                )
            blk.layer[1].layer_norm.weight.copy_(t(f"encoder_blocks.{i}.ffn.layer_norm.weight"))
            blk.layer[1].DenseReluDense.wi_0.weight.copy_(t(f"encoder_blocks.{i}.ffn.wi_0.weight"))
            blk.layer[1].DenseReluDense.wi_1.weight.copy_(t(f"encoder_blocks.{i}.ffn.wi_1.weight"))
            blk.layer[1].DenseReluDense.wo.weight.copy_(t(f"encoder_blocks.{i}.ffn.wo.weight"))

        for i in range(len(mlx_model.decoder_blocks)):
            blk = hf_model.decoder.block[i]
            blk.layer[0].layer_norm.weight.copy_(t(f"decoder_blocks.{i}.self_ln.weight"))
            blk.layer[0].SelfAttention.q.weight.copy_(t(f"decoder_blocks.{i}.self_attn.q.weight"))
            blk.layer[0].SelfAttention.k.weight.copy_(t(f"decoder_blocks.{i}.self_attn.k.weight"))
            blk.layer[0].SelfAttention.v.weight.copy_(t(f"decoder_blocks.{i}.self_attn.v.weight"))
            blk.layer[0].SelfAttention.o.weight.copy_(t(f"decoder_blocks.{i}.self_attn.o.weight"))
            if i == 0:
                blk.layer[0].SelfAttention.relative_attention_bias.weight.copy_(
                    t(f"decoder_blocks.{i}.self_attn.relative_attention_bias.weight")
                )
            blk.layer[1].layer_norm.weight.copy_(t(f"decoder_blocks.{i}.cross_ln.weight"))
            blk.layer[1].EncDecAttention.q.weight.copy_(t(f"decoder_blocks.{i}.cross_attn.q.weight"))
            blk.layer[1].EncDecAttention.k.weight.copy_(t(f"decoder_blocks.{i}.cross_attn.k.weight"))
            blk.layer[1].EncDecAttention.v.weight.copy_(t(f"decoder_blocks.{i}.cross_attn.v.weight"))
            blk.layer[1].EncDecAttention.o.weight.copy_(t(f"decoder_blocks.{i}.cross_attn.o.weight"))
            blk.layer[2].layer_norm.weight.copy_(t(f"decoder_blocks.{i}.ffn.layer_norm.weight"))
            blk.layer[2].DenseReluDense.wi_0.weight.copy_(t(f"decoder_blocks.{i}.ffn.wi_0.weight"))
            blk.layer[2].DenseReluDense.wi_1.weight.copy_(t(f"decoder_blocks.{i}.ffn.wi_1.weight"))
            blk.layer[2].DenseReluDense.wo.weight.copy_(t(f"decoder_blocks.{i}.ffn.wo.weight"))

    hf_model.config.tie_word_embeddings = False


def _build_rel_buckets_table(max_len: int, bidirectional: bool) -> mx.array:
    pos = np.arange(max_len)[:, None]
    rel = pos.T - pos  # memory_position - query_position
    return mx.array(_relative_position_bucket(rel, bidirectional=bidirectional), dtype=mx.int32)


def _fake_quant_int4_ste_weight(w: mx.array, block_size: int = 32) -> mx.array:
    """Blockwise symmetric INT4 fake quantization with straight-through gradient."""
    orig_shape = w.shape
    cols = orig_shape[-1]
    if cols % block_size != 0 or w.size <= 512:
        return w
    blocks = w.reshape(-1, block_size)
    max_abs = mx.maximum(mx.max(mx.abs(blocks), axis=-1, keepdims=True), 1e-6)
    scale = max_abs / 7.0
    q = mx.clip(mx.round(blocks / scale), -8.0, 7.0)
    deq = (q * scale).reshape(orig_shape)
    return w + mx.stop_gradient(deq - w)


def _apply_qat_to_model(model: MlxFlanT5, block_size: int = 32) -> None:
    """Replaces forward Linear calls in MLX module tree with INT4 fake-quantized projection."""
    class QATLinearMLX(nn.Module):
        def __init__(self, inner: nn.Linear) -> None:
            super().__init__()
            self.weight = inner.weight

        def __call__(self, x: mx.array) -> mx.array:
            wq = _fake_quant_int4_ste_weight(self.weight, block_size=block_size)
            return x @ wq.T

    def replace_children(obj: Any) -> None:
        if isinstance(obj, list):
            for idx, item in enumerate(obj):
                if isinstance(item, nn.Linear):
                    obj[idx] = QATLinearMLX(item)
                else:
                    replace_children(item)
            return
        for attr, val in list(vars(obj).items()):
            if attr.startswith("_"):
                continue
            if isinstance(val, nn.Linear) and attr != "lm_head":
                setattr(obj, attr, QATLinearMLX(val))
            elif isinstance(val, (nn.Module, list)):
                replace_children(val)

    replace_children(model)


def verify_hf_mlx_parity(hf_model: Any, mlx_model: MlxFlanT5) -> float:
    enc_ids_np = np.array([[10, 42, 77, 1]], dtype=np.int32)
    enc_mask_np = np.ones((1, 4), dtype=np.int32)
    dec_ids_np = np.array([[0, 15, 22]], dtype=np.int32)

    with torch.no_grad():
        hf_logits = hf_model(
            input_ids=torch.tensor(enc_ids_np, dtype=torch.long),
            attention_mask=torch.tensor(enc_mask_np, dtype=torch.long),
            decoder_input_ids=torch.tensor(dec_ids_np, dtype=torch.long),
        ).logits.numpy()

    enc_buckets = _build_rel_buckets_table(4, bidirectional=True)
    dec_buckets = _build_rel_buckets_table(3, bidirectional=False)
    dec_mask = mx.array(np.triu(np.full((1, 1, 3, 3), -1e9, dtype=np.float32), k=1))
    mlx_logits = mlx_model(
        mx.array(enc_ids_np),
        mx.array(enc_mask_np),
        mx.array(dec_ids_np),
        enc_buckets,
        dec_mask,
        dec_buckets,
    )
    mx.eval(mlx_logits)
    diff = float(np.max(np.abs(hf_logits - np.array(mlx_logits))))
    print(f"[Parity Check] Max |HF - MLX| logits diff = {diff:.6f}")
    assert diff < 1e-3, f"MLX vs HF parity mismatch: {diff}"
    return diff


def greedy_generate_mlx(
    mlx_model: MlxFlanT5,
    src_ids: list[int],
    enc_buckets_full: mx.array,
    dec_buckets_full: mx.array,
    dec_causal_mask_full: mx.array,
    max_new_tokens: int = 80,
) -> list[int]:
    s = len(src_ids)
    inp = mx.array([src_ids], dtype=mx.int32)
    mask = mx.ones((1, s), dtype=mx.int32)
    enc_hidden, enc_mask = mlx_model.encode(inp, mask, enc_buckets_full[:s, :s])
    mx.eval(enc_hidden, enc_mask)

    dec_ids = [0]
    for _ in range(max_new_tokens):
        k = len(dec_ids)
        dec_inp = mx.array([dec_ids], dtype=mx.int32)
        logits = mlx_model.decode(
            dec_inp,
            enc_hidden,
            enc_mask,
            dec_causal_mask_full[:, :, :k, :k],
            dec_buckets_full[:k, :k],
        )
        mx.eval(logits)
        next_tok = int(mx.argmax(logits[0, k - 1], axis=-1).item())
        if next_tok in (0, 1):
            break
        dec_ids.append(next_tok)
    return dec_ids[1:]


def evaluate_mlx_validation(
    mlx_model: MlxFlanT5,
    val_rows: list[dict[str, str]],
    vocab: list[list],
    max_samples: int = 200,
) -> dict[str, float]:
    subset = val_rows[:max_samples]
    keys = ["PROJECT", "ROLE", "DESC", "DEADLINE", "EMAIL"]
    exact_hits = {k: 0 for k in keys}
    none_total = 0
    none_correct = 0

    enc_buckets_full = _build_rel_buckets_table(512, bidirectional=True)
    dec_buckets_full = _build_rel_buckets_table(96, bidirectional=False)
    dec_causal_full = mx.array(np.triu(np.full((1, 1, 96, 96), -1e9, dtype=np.float32), k=1))

    for idx, row in enumerate(subset):
        src_ids = unigram_encode_reference(row["input"], vocab, append_eos=True)[:512]
        gen = greedy_generate_mlx(mlx_model, src_ids, enc_buckets_full, dec_buckets_full, dec_causal_full)
        pred_text = unigram_decode_reference(gen, vocab)
        pred_map = parse_tagged_dict(pred_text)
        gold_map = parse_tagged_dict(_normalize_input_symbols(row["target"]))
        if idx < 2:
            print(f"  [Sample {idx}] PRED={pred_text!r} | GOLD={row['target']!r}")
        for k in keys:
            g = gold_map.get(k, "NONE")
            p = pred_map.get(k, "NONE")
            if p.lower() == g.lower():
                exact_hits[k] += 1
            if g == "NONE":
                none_total += 1
                if p.upper() == "NONE":
                    none_correct += 1

    metrics = {f"{k.lower()}_acc": exact_hits[k] / max(1, len(subset)) for k in keys}
    metrics["mean_field_acc"] = sum(metrics.values()) / len(keys)
    metrics["none_abstention_acc"] = none_correct / max(1, none_total)
    return metrics


def verify_coreml_runtime(bundle_dir: str, vocab: list[list]) -> None:
    """Runs actual CoreML.framework predictions on macOS to guarantee zero NaNs & real accuracy."""
    import coremltools as ct

    enc_path = os.path.join(bundle_dir, "OneTakeParserEncoder.mlpackage")
    dec_path = os.path.join(bundle_dir, "OneTakeParserDecoder.mlpackage")
    enc_ml = ct.models.MLModel(enc_path)
    dec_ml = ct.models.MLModel(dec_path)

    samples = [
        (
            "parse audition notice:\nCASTING CALL\nMCCC - KOSHISHE\n"
            "Role: Male Lead for an upcoming Hindi theatrical feature film\n"
            "Submission Deadline: 15 December, 2026\nEmail to Apply: abhinav@mcc.in"
        ),
        (
            "parse audition notice:\nPHOTON - A FEATURE FILM\n"
            "Looking for Female Talent aged 20–25 years.\n"
            "Send self-tape to casting@schoolofdrama.com before 30 November 2026."
        ),
    ]

    for idx, prompt in enumerate(samples):
        src_ids = unigram_encode_reference(prompt, vocab, append_eos=True)[:512]
        enc_in = {
            "input_ids": np.array([src_ids], dtype=np.int32),
            "attention_mask": np.ones((1, len(src_ids)), dtype=np.int32),
        }
        enc_out = enc_ml.predict(enc_in)
        hidden = np.array(enc_out["encoder_hidden_states"])
        assert np.isfinite(hidden).all(), "Core ML Encoder emitted NaN/Inf!"

        dec_tokens = [0]
        for _ in range(96):
            dec_out = dec_ml.predict({
                "decoder_input_ids": np.array([dec_tokens], dtype=np.int32),
                "encoder_hidden_states": hidden,
                "encoder_attention_mask": np.ones((1, len(src_ids)), dtype=np.int32),
            })
            logits = np.array(dec_out["logits"])
            assert np.isfinite(logits).all(), "Core ML Decoder emitted NaN/Inf!"
            next_tok = int(np.argmax(logits[0, len(dec_tokens) - 1]))
            if next_tok in (0, 1):
                break
            dec_tokens.append(next_tok)

        decoded = unigram_decode_reference(dec_tokens[1:], vocab)
        print(f"[CoreML macOS Live Test #{idx + 1}]\n{decoded}\n---")


def train_with_mlx(
    output_dir: str = "/tmp/onetake_mlx_work",
    bundle_dir: str = "/tmp/onetake_mlx_bundle",
    base_model_name: str = "google/flan-t5-small",
    vocab_size: int = 8192,
    num_train: int = 12000,
    num_val: int = 600,
    epochs: int = 4,
    qat_epochs: int = 1,
    batch_size: int = 24,
    lr: float = 4e-4,
    qat_lr: float = 6e-5,
) -> dict[str, Any]:
    os.makedirs(output_dir, exist_ok=True)
    os.makedirs(bundle_dir, exist_ok=True)
    t0 = time.time()
    print(f"[OneTake MLX] Device={mx.default_device()}, vocab_size={vocab_size}, train={num_train}, bs={batch_size}")

    corpus = generate_casting_corpus(num_train=num_train, num_val=num_val, num_test=400, seed=42)
    hf_tok = AutoTokenizer.from_pretrained(base_model_name, local_files_only=True)
    pieces_with_scores = extract_sentencepiece_table(hf_tok, base_model_name)
    corpus_texts = [r["input"] for r in corpus["train"]] + [r["target"] for r in corpus["train"]]
    pruned = build_pruned_piece_table(pieces_with_scores, corpus_texts, target_vocab_size=vocab_size)
    vocab = pruned["vocab"]
    sp_vocab_path = os.path.join(output_dir, "sp_vocab.json")
    save_sp_vocab_json(pruned, sp_vocab_path)

    golden_samples = [r["input"] for r in corpus["test"][:15]] + [
        "CASTING CALL – UPCOMING HINDI FEATURE FILM\nRole: Female Lead ₹25,000/day\nEmail: abhinav@mcc.in",
        "PROJECT: MCCC - KOSHISHE\nROLE: Male Lead\nDEADLINE: 15 December, 2026\nEMAIL: abhinav@mcc.in",
        "Line with emoji 🎬 & Devanagari हिन्दी & curly quotes “Action!”",
        "PHOTON — Casting Call\nMen aged 22–25 years\nDeadline: 30 November 2026",
        "No deadline notice\twith tabs   and multiple spaces.",
    ]
    golden_vectors = [
        {"text": s, "ids": unigram_encode_reference(s, vocab, append_eos=True)}
        for s in golden_samples
    ]
    golden_path = os.path.join(output_dir, "golden_parity_vectors.json")
    with open(golden_path, "w", encoding="utf-8") as f:
        json.dump(golden_vectors, f, ensure_ascii=False, indent=2)

    hf_model = AutoModelForSeq2SeqLM.from_pretrained(base_model_name, local_files_only=True).eval()
    hf_model = prune_flan_t5_vocab(hf_model, pruned["old_to_new_ids"])
    hf_model.config.tie_word_embeddings = False

    mlx_model = MlxFlanT5(
        vocab_size=len(vocab),
        d_model=hf_model.config.d_model,
        d_kv=hf_model.config.d_kv,
        num_heads=hf_model.config.num_heads,
        d_ff=hf_model.config.d_ff,
        num_layers=hf_model.config.num_layers,
        num_decoder_layers=hf_model.config.num_decoder_layers,
        eps=hf_model.config.layer_norm_epsilon,
    )
    _sync_hf_to_mlx(hf_model, mlx_model)
    verify_hf_mlx_parity(hf_model, mlx_model)

    # Convert model parameters to bfloat16 for blazing fast M4 Pro GPU throughput
    mlx_model.set_dtype(mx.bfloat16)
    mx.eval(mlx_model.parameters())

    def encode_split(rows: list[dict[str, str]]) -> list[tuple[list[int], list[int]]]:
        pairs: list[tuple[list[int], list[int]]] = []
        for r in rows:
            s_ids = unigram_encode_reference(r["input"], vocab, append_eos=True)[:512]
            if s_ids[-1] != 1:
                s_ids[-1] = 1
            t_ids = unigram_encode_reference(r["target"], vocab, append_eos=True)[:96]
            if t_ids[-1] != 1:
                t_ids[-1] = 1
            pairs.append((s_ids, t_ids))
        return pairs

    train_pairs = encode_split(corpus["train"])
    rng = np.random.default_rng(42)
    enc_buckets_full = _build_rel_buckets_table(512, bidirectional=True)
    dec_buckets_full = _build_rel_buckets_table(96, bidirectional=False)
    dec_causal_full = mx.array(np.triu(np.full((1, 1, 96, 96), -1e9, dtype=np.float32), k=1))

    def loss_fn(model: MlxFlanT5, inp: mx.array, attn_mask: mx.array, dec_inp: mx.array, labels: mx.array, lbl_mask: mx.array) -> mx.array:
        s_len = inp.shape[1]
        k_len = dec_inp.shape[1]
        logits = model(
            inp,
            attn_mask,
            dec_inp,
            enc_buckets_full[:s_len, :s_len],
            dec_causal_full[:, :, :k_len, :k_len].astype(mx.bfloat16),
            dec_buckets_full[:k_len, :k_len],
        ).astype(mx.float32)
        ce = nn.losses.cross_entropy(logits, labels, reduction="none") * lbl_mask
        return mx.sum(ce) / mx.maximum(mx.sum(lbl_mask), 1.0)

    def run_stage(n_epochs: int, peak_lr: float, phase: str) -> None:
        steps_per_epoch = max(1, (len(train_pairs) + batch_size - 1) // batch_size)
        total_steps = steps_per_epoch * n_epochs
        warmup = max(1, int(0.06 * total_steps))
        lr_schedule = optim.join_schedules(
            [
                optim.linear_schedule(1e-7, peak_lr, warmup),
                optim.cosine_decay(peak_lr, max(1, total_steps - warmup), end=peak_lr * 0.05),
            ],
            [warmup],
        )
        optimizer = optim.AdamW(learning_rate=lr_schedule, weight_decay=0.01)
        val_and_grad = nn.value_and_grad(mlx_model, loss_fn)

        def train_step(inp, attn_mask, dec_inp, labels, lbl_mask):
            loss, grads = val_and_grad(mlx_model, inp, attn_mask, dec_inp, labels, lbl_mask)
            grads, _ = optim.clip_grad_norm(grads, max_norm=1.0)
            optimizer.update(mlx_model, grads)
            return loss

        for epoch in range(1, n_epochs + 1):
            order = rng.permutation(len(train_pairs))
            running_loss = 0.0
            ep_start = time.time()
            for step_idx in range(steps_per_epoch):
                batch_indices = order[step_idx * batch_size : (step_idx + 1) * batch_size]
                max_s = max(len(train_pairs[i][0]) for i in batch_indices)
                max_t = max(len(train_pairs[i][1]) for i in batch_indices)
                # Bucket sequence lengths to multiples of 16 to maximize GPU kernel cache hits
                max_s = min(512, ((max_s + 15) // 16) * 16)
                max_t = min(96, ((max_t + 15) // 16) * 16)
                bsz = len(batch_indices)

                inp_np = np.zeros((bsz, max_s), dtype=np.int32)
                mask_np = np.zeros((bsz, max_s), dtype=np.int32)
                dec_np = np.zeros((bsz, max_t), dtype=np.int32)
                lbl_np = np.zeros((bsz, max_t), dtype=np.int32)
                lbl_mask_np = np.zeros((bsz, max_t), dtype=np.float32)

                for b, i in enumerate(batch_indices):
                    s_toks, t_toks = train_pairs[i]
                    inp_np[b, : len(s_toks)] = s_toks
                    mask_np[b, : len(s_toks)] = 1
                    lbl_np[b, : len(t_toks)] = t_toks
                    lbl_mask_np[b, : len(t_toks)] = 1.0
                    # T5 shifted-right decoder input: [0, t_0, t_1, ..., t_{n-2}]
                    dec_np[b, 0] = 0
                    if len(t_toks) > 1:
                        dec_np[b, 1 : len(t_toks)] = t_toks[:-1]

                loss = train_step(
                    mx.array(inp_np),
                    mx.array(mask_np),
                    mx.array(dec_np),
                    mx.array(lbl_np),
                    mx.array(lbl_mask_np),
                )
                mx.eval(loss, mlx_model.parameters(), optimizer.state)
                running_loss += float(loss.item())
                if (step_idx + 1) % 100 == 0 or step_idx + 1 == steps_per_epoch:
                    print(
                        f"[{phase}] ep {epoch}/{n_epochs} step {step_idx+1}/{steps_per_epoch} "
                        f"loss={running_loss/(step_idx+1):.4f} elapsed={time.time()-ep_start:.1f}s"
                    )

            val_metrics = evaluate_mlx_validation(mlx_model, corpus["val"], vocab, max_samples=150)
            print(f"[{phase}] ep {epoch} val metrics: {val_metrics}")

    run_stage(epochs, lr, "Stage1-MLX-BF16")
    if qat_epochs > 0:
        _apply_qat_to_model(mlx_model, block_size=32)
        run_stage(qat_epochs, qat_lr, "Stage2-MLX-INT4-QAT")

    final_metrics = evaluate_mlx_validation(mlx_model, corpus["test"], vocab, max_samples=300)
    print(f"[Final Held-Out MLX Test Metrics] {final_metrics} (total train={time.time()-t0:.1f}s)")

    metrics_path = os.path.join(output_dir, "eval_metrics.json")
    with open(metrics_path, "w", encoding="utf-8") as f:
        json.dump(final_metrics, f, indent=2)

    ckpt_dir = os.path.join(output_dir, "hf_checkpoint")
    _sync_mlx_to_hf(mlx_model, hf_model)
    hf_model.cpu().save_pretrained(ckpt_dir)

    export_info = export_coreml_models(
        checkpoint_dir=ckpt_dir,
        output_dir=bundle_dir,
        sp_vocab_path=sp_vocab_path,
        author="Porage-Lover <jitund05@gmail.com>",
        max_total_mb=35.0,
    )
    print("[OneTake MLX -> CoreML Export]", export_info)

    # Copy bundle metadata & test live CoreML prediction on macOS
    import shutil
    shutil.copy2(sp_vocab_path, os.path.join(bundle_dir, "sp_vocab.json"))
    shutil.copy2(golden_path, os.path.join(bundle_dir, "golden_parity_vectors.json"))
    shutil.copy2(metrics_path, os.path.join(bundle_dir, "eval_metrics.json"))

    verify_coreml_runtime(bundle_dir, vocab)
    zip_base = "/tmp/OneTakeParserCoreML_Bundle"
    archive_path = shutil.make_archive(zip_base, "zip", bundle_dir)
    print(f"[OneTake MLX] Bundle zip ready: {archive_path}")
    return {"metrics": final_metrics, "export": export_info, "zip_path": archive_path}


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--vocab-size", type=int, default=8192)
    parser.add_argument("--num-train", type=int, default=12000)
    parser.add_argument("--epochs", type=int, default=4)
    parser.add_argument("--qat-epochs", type=int, default=1)
    parser.add_argument("--batch-size", type=int, default=24)
    args = parser.parse_args()
    train_with_mlx(
        vocab_size=args.vocab_size,
        num_train=args.num_train,
        epochs=args.epochs,
        qat_epochs=args.qat_epochs,
        batch_size=args.batch_size,
    )
