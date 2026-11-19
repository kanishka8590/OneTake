"""Flan-T5-Small vocabulary surgery, full fine-tuning, and 4-bit blockwise QAT."""

from __future__ import annotations

import argparse
import json
import math
import os
from typing import Any

import torch
import torch.nn as nn
import torch.nn.functional as F
from torch.utils.data import DataLoader, Dataset
from transformers import AutoModelForSeq2SeqLM, AutoTokenizer, get_cosine_schedule_with_warmup

from dataset_generator import generate_casting_corpus
from vocab_surgery import (
    _normalize_input_symbols,
    build_pruned_piece_table,
    save_sp_vocab_json,
    unigram_decode_reference,
    unigram_encode_reference,
)


def extract_sentencepiece_table(tokenizer: Any, model_name: str = "google/flan-t5-small") -> list[tuple[str, float]]:
    """Extracts `(piece, score)` pairs from T5 SentencePiece plus sentinel tokens (up to 32100)."""
    sp = getattr(tokenizer, "sp_model", None)
    if sp is None:
        import sentencepiece as spm
        from huggingface_hub import hf_hub_download

        sp_file = getattr(tokenizer, "vocab_file", None) or hf_hub_download(model_name, "spiece.model", local_files_only=True)
        sp = spm.SentencePieceProcessor(model_file=sp_file)

    pieces: list[tuple[str, float]] = [
        (sp.id_to_piece(i), float(sp.get_score(i))) for i in range(sp.get_piece_size())
    ]
    # Append HF T5 added sentinel tokens (<extra_id_99> .. <extra_id_0> at indices 32000..32099)
    total_vocab = max(len(pieces), int(getattr(tokenizer, "vocab_size", len(pieces))))
    if len(pieces) < total_vocab:
        for idx in range(len(pieces), total_vocab):
            tok = tokenizer.convert_ids_to_tokens(idx)
            pieces.append((tok if isinstance(tok, str) else f"<extra_id_{total_vocab - 1 - idx}>", -10.0))
    return pieces


def prune_flan_t5_vocab(
    model: nn.Module,
    old_to_new_ids: list[int],
) -> nn.Module:
    """Slices T5 embedding and LM head weights to the pruned vocabulary indices."""
    new_vocab_size = len(old_to_new_ids)
    idx_tensor = torch.tensor(old_to_new_ids, dtype=torch.long)

    with torch.no_grad():
        old_shared = model.shared.weight.data[idx_tensor].clone()
        old_lm_head = model.lm_head.weight.data[idx_tensor].clone()

        new_shared = nn.Embedding(new_vocab_size, model.config.d_model)
        new_shared.weight.data.copy_(old_shared)
        model.shared = new_shared
        model.encoder.set_input_embeddings(new_shared)
        model.decoder.set_input_embeddings(new_shared)

        new_lm_head = nn.Linear(model.config.d_model, new_vocab_size, bias=False)
        new_lm_head.weight.data.copy_(old_lm_head)
        model.lm_head = new_lm_head

    model.config.vocab_size = new_vocab_size
    model.config.pad_token_id = 0
    model.config.eos_token_id = 1
    model.config.decoder_start_token_id = 0
    return model


class NoticeSeq2SeqDataset(Dataset):
    def __init__(
        self,
        rows: list[dict[str, str]],
        vocab: list[list],
        max_source_len: int = 512,
        max_target_len: int = 96,
    ) -> None:
        self.samples: list[tuple[list[int], list[int]]] = []
        for row in rows:
            src_ids = unigram_encode_reference(row["input"], vocab, append_eos=True)[:max_source_len]
            if src_ids[-1] != 1:
                src_ids[-1] = 1
            tgt_ids = unigram_encode_reference(row["target"], vocab, append_eos=True)[:max_target_len]
            if tgt_ids[-1] != 1:
                tgt_ids[-1] = 1
            self.samples.append((src_ids, tgt_ids))

    def __len__(self) -> int:
        return len(self.samples)

    def __getitem__(self, idx: int) -> tuple[list[int], list[int]]:
        return self.samples[idx]


def collate_seq2seq(batch: list[tuple[list[int], list[int]]]) -> dict[str, torch.Tensor]:
    max_src = max(len(x[0]) for x in batch)
    max_tgt = max(len(x[1]) for x in batch)
    bsz = len(batch)

    input_ids = torch.zeros((bsz, max_src), dtype=torch.long)
    attention_mask = torch.zeros((bsz, max_src), dtype=torch.long)
    labels = torch.full((bsz, max_tgt), -100, dtype=torch.long)

    for i, (src, tgt) in enumerate(batch):
        input_ids[i, : len(src)] = torch.tensor(src, dtype=torch.long)
        attention_mask[i, : len(src)] = 1
        labels[i, : len(tgt)] = torch.tensor(tgt, dtype=torch.long)

    return {
        "input_ids": input_ids,
        "attention_mask": attention_mask,
        "labels": labels,
    }


def _fake_quant_int4_blockwise(w: torch.Tensor, block_size: int = 32) -> torch.Tensor:
    """Straight-through estimator simulating symmetric 4-bit per-block quantization."""
    orig_shape = w.shape
    flat = w.reshape(-1, orig_shape[-1])
    pad_cols = (block_size - (flat.shape[1] % block_size)) % block_size
    if pad_cols:
        flat_padded = F.pad(flat, (0, pad_cols))
    else:
        flat_padded = flat
    blocks = flat_padded.reshape(-1, block_size)
    max_abs = blocks.abs().amax(dim=-1, keepdim=True).clamp(min=1e-6)
    scale = max_abs / 7.0
    q = torch.clamp(torch.round(blocks / scale), -8, 7)
    deq = q * scale
    if pad_cols:
        deq = deq.reshape(flat.shape[0], -1)[:, : flat.shape[1]]
    return w + (deq.reshape(orig_shape) - w).detach()


class QATLinear(nn.Module):
    def __init__(self, linear: nn.Linear, block_size: int = 32) -> None:
        super().__init__()
        self.linear = linear
        self.block_size = block_size

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        w_q = _fake_quant_int4_blockwise(self.linear.weight, self.block_size)
        return F.linear(x, w_q, self.linear.bias)


def wrap_linear_modules_for_qat(module: nn.Module, block_size: int = 32) -> nn.Module:
    for name, child in list(module.named_children()):
        if isinstance(child, nn.Linear):
            setattr(module, name, QATLinear(child, block_size=block_size))
        else:
            wrap_linear_modules_for_qat(child, block_size=block_size)
    return module


def unwrap_qat_modules(module: nn.Module) -> nn.Module:
    for name, child in list(module.named_children()):
        if isinstance(child, QATLinear):
            setattr(module, name, child.linear)
        else:
            unwrap_qat_modules(child)
    return module


def parse_tagged_dict(raw: str) -> dict[str, str]:
    parsed: dict[str, str] = {}
    for line in raw.splitlines():
        if ":" not in line:
            continue
        k, v = line.split(":", 1)
        parsed[k.strip().upper()] = v.strip()
    return parsed


@torch.no_grad()
def evaluate_validation(
    model: nn.Module,
    val_rows: list[dict[str, str]],
    vocab: list[list],
    device: torch.device,
    max_samples: int = 250,
) -> dict[str, float]:
    model.eval()
    subset = val_rows[:max_samples]
    keys = ["PROJECT", "ROLE", "DESC", "DEADLINE", "EMAIL"]
    exact_hits = {k: 0 for k in keys}
    none_total = 0
    none_correct = 0

    for idx, row in enumerate(subset):
        src_ids = unigram_encode_reference(row["input"], vocab, append_eos=True)[:512]
        inp = torch.tensor([src_ids], dtype=torch.long, device=device)
        gen = model.generate(input_ids=inp, max_new_tokens=96, do_sample=False, eos_token_id=1, pad_token_id=0)
        pred_text = unigram_decode_reference(gen[0].tolist(), vocab)
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


def train_pipeline(
    output_dir: str,
    base_model_name: str = "google/flan-t5-small",
    vocab_size: int = 8192,
    num_train: int = 18000,
    num_val: int = 1000,
    epochs: int = 5,
    qat_epochs: int = 1,
    batch_size: int = 32,
    lr: float = 3e-4,
    qat_lr: float = 5e-5,
) -> dict[str, Any]:
    os.makedirs(output_dir, exist_ok=True)
    device = torch.device("cuda" if torch.cuda.is_available() else ("mps" if torch.backends.mps.is_available() else "cpu"))
    use_bf16 = device.type == "cuda" and torch.cuda.is_bf16_supported()

    print(f"[OneTake] Device={device}, bf16={use_bf16}, vocab_size={vocab_size}")
    corpus = generate_casting_corpus(num_train=num_train, num_val=num_val, num_test=500, seed=42)

    hf_tok = AutoTokenizer.from_pretrained(base_model_name, use_fast=False)
    pieces_with_scores = extract_sentencepiece_table(hf_tok)
    corpus_texts = [r["input"] for r in corpus["train"]] + [r["target"] for r in corpus["train"]]
    pruned = build_pruned_piece_table(pieces_with_scores, corpus_texts, target_vocab_size=vocab_size)
    vocab = pruned["vocab"]
    save_sp_vocab_json(pruned, os.path.join(output_dir, "sp_vocab.json"))

    # Save 20 golden parity vectors for Swift `UnigramTokenizer` tests
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
    with open(os.path.join(output_dir, "golden_parity_vectors.json"), "w", encoding="utf-8") as f:
        json.dump(golden_vectors, f, ensure_ascii=False, indent=2)

    model = AutoModelForSeq2SeqLM.from_pretrained(base_model_name)
    model = prune_flan_t5_vocab(model, pruned["old_to_new_ids"]).to(device)

    train_ds = NoticeSeq2SeqDataset(corpus["train"], vocab)
    train_loader = DataLoader(train_ds, batch_size=batch_size, shuffle=True, collate_fn=collate_seq2seq)

    def run_epochs(n_epochs: int, learning_rate: float, label_smoothing: float, phase: str) -> None:
        optimizer = torch.optim.AdamW(model.parameters(), lr=learning_rate, weight_decay=0.01)
        total_steps = max(1, len(train_loader) * n_epochs)
        scheduler = get_cosine_schedule_with_warmup(optimizer, int(0.06 * total_steps), total_steps)
        loss_fn = nn.CrossEntropyLoss(ignore_index=-100, label_smoothing=label_smoothing)

        for epoch in range(1, n_epochs + 1):
            model.train()
            running = 0.0
            for step, batch in enumerate(train_loader, start=1):
                optimizer.zero_grad(set_to_none=True)
                inp = batch["input_ids"].to(device)
                mask = batch["attention_mask"].to(device)
                lbl = batch["labels"].to(device)
                with torch.autocast(device_type=device.type, dtype=torch.bfloat16, enabled=use_bf16):
                    out = model(input_ids=inp, attention_mask=mask, labels=lbl)
                    loss = loss_fn(out.logits.view(-1, out.logits.size(-1)), lbl.view(-1))
                loss.backward()
                torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
                optimizer.step()
                scheduler.step()
                running += float(loss.item())
                if step % 150 == 0:
                    print(f"[{phase}] epoch {epoch}/{n_epochs} step {step}/{len(train_loader)} loss={running/step:.4f}")
            metrics = evaluate_validation(model, corpus["val"], vocab, device)
            print(f"[{phase}] epoch {epoch} val metrics: {metrics}")

    run_epochs(epochs, lr, label_smoothing=0.05, phase="Stage1-BF16")
    if qat_epochs > 0:
        wrap_linear_modules_for_qat(model, block_size=32)
        run_epochs(qat_epochs, qat_lr, label_smoothing=0.0, phase="Stage2-INT4-QAT")
        unwrap_qat_modules(model)

    final_metrics = evaluate_validation(model, corpus["test"], vocab, device, max_samples=500)
    print(f"[Final Held-Out Test Metrics] {final_metrics}")

    ckpt_dir = os.path.join(output_dir, "hf_checkpoint")
    model.cpu().save_pretrained(ckpt_dir)
    with open(os.path.join(output_dir, "eval_metrics.json"), "w", encoding="utf-8") as f:
        json.dump(final_metrics, f, indent=2)
    return final_metrics


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-dir", default="artifacts/flan_t5_onetake")
    parser.add_argument("--vocab-size", type=int, default=8192)
    parser.add_argument("--num-train", type=int, default=18000)
    parser.add_argument("--epochs", type=int, default=5)
    parser.add_argument("--qat-epochs", type=int, default=1)
    parser.add_argument("--batch-size", type=int, default=32)
    args = parser.parse_args()
    train_pipeline(
        output_dir=args.output_dir,
        vocab_size=args.vocab_size,
        num_train=args.num_train,
        epochs=args.epochs,
        qat_epochs=args.qat_epochs,
        batch_size=args.batch_size,
    )
