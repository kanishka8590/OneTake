"""Flan-T5 vocabulary surgery & pure-Python SentencePiece Unigram Viterbi reference.

Both Python training/evaluation and Swift `UnigramTokenizer` share the exact `sp_vocab.json`
table and preserve newlines (`\\n`) as `<0x0A>` so multi-line OCR layouts and tagged output
lines round-trip losslessly with 100% token-ID parity.
"""

from __future__ import annotations

import json
import math
import re
from collections import Counter
from typing import Iterable


_BYTE_TOKENS = [f"<0x{b:02X}>" for b in range(256)]
_DOMAIN_ESSENTIALS = [
    "\u2581",
    ":",
    "-",
    "/",
    ".",
    ",",
    "@",
    "(",
    ")",
    "|",
    "&",
    "!",
    "?",
    "%",
    "'",
    '"',
    "\u2581PROJECT",
    "\u2581ROLE",
    "\u2581DESC",
    "\u2581DEADLINE",
    "\u2581EMAIL",
    "\u2581NONE",
    "PROJECT",
    "ROLE",
    "DESC",
    "DEADLINE",
    "EMAIL",
    "NONE",
    "parse",
    "\u2581parse",
    "\u2581audition",
    "\u2581notice",
]


_SYMBOL_REPLACEMENTS = (
    ("\r\n", "\n"),
    ("\r", "\n"),
    ("\u2013", "-"),   # en dash
    ("\u2014", "-"),   # em dash
    ("\u2212", "-"),   # minus sign
    ("\u2018", "'"),   # left single quote
    ("\u2019", "'"),   # right single quote
    ("\u201c", '"'),   # left double quote
    ("\u201d", '"'),   # right double quote
    ("\u2026", "..."), # ellipsis
    ("\u20b9", "Rs."), # rupee symbol
    ("\u00a0", " "),   # nbsp
)


def _normalize_input_symbols(text: str) -> str:
    """Normalizes common casting-flyer punctuation missing from T5's non-byte vocab."""
    for src, dst in _SYMBOL_REPLACEMENTS:
        if src in text:
            text = text.replace(src, dst)
    return text


def _split_preserving_newlines(text: str) -> list[tuple[str, bool]]:
    """Splits text into chunks, returning `(chunk, is_newline)` pairs."""
    text = _normalize_input_symbols(text)
    parts: list[tuple[str, bool]] = []
    for idx, line in enumerate(text.split("\n")):
        if idx > 0:
            parts.append(("\n", True))
        if line:
            parts.append((line, False))
    return parts


def _normalize_line_segment(segment: str) -> str:
    """Normalizes spaces to SentencePiece `▁` with dummy leading `▁` (exact Swift mirror)."""
    collapsed = re.sub(r"[ \t\r]+", " ", segment).strip(" ")
    if not collapsed:
        return ""
    return "\u2581" + collapsed.replace(" ", "\u2581")


def unigram_encode_reference(
    text: str,
    vocab: list[list],
    append_eos: bool = True,
) -> list[int]:
    """Viterbi DP SentencePiece Unigram encoder matching Swift `UnigramTokenizer`."""
    piece_to_id: dict[str, int] = {}
    piece_to_score: dict[str, float] = {}
    max_piece_len = 1
    for idx, entry in enumerate(vocab):
        piece, score = entry[0], float(entry[1])
        piece_to_id[piece] = idx
        piece_to_score[piece] = score
        if not (piece.startswith("<") and piece.endswith(">")):
            if len(piece) > max_piece_len:
                max_piece_len = len(piece)

    eos_id = piece_to_id.get("</s>", 1)
    unk_id = piece_to_id.get("<unk>", 2)
    newline_id = piece_to_id.get("<0x0A>", piece_to_id.get("<extra_id_0>", unk_id))
    ids: list[int] = []

    for segment, is_newline in _split_preserving_newlines(text):
        if is_newline:
            ids.append(newline_id)
            continue

        norm = _normalize_line_segment(segment)
        if not norm:
            continue

        n = len(norm)
        best_score = [-math.inf] * (n + 1)
        best_len = [0] * (n + 1)
        best_score[0] = 0.0

        for i in range(n):
            if best_score[i] == -math.inf:
                continue
            limit = min(n, i + max_piece_len)
            matched_any = False
            for j in range(i + 1, limit + 1):
                sub = norm[i:j]
                if sub in piece_to_score:
                    cand = best_score[i] + piece_to_score[sub]
                    if cand > best_score[j]:
                        best_score[j] = cand
                        best_len[j] = j - i
                        matched_any = True
            # Single-character byte-fallback transition when no piece covers norm[i]
            if best_len[i + 1] == 0:
                fallback_penalty = -30.0
                cand = best_score[i] + fallback_penalty
                if cand > best_score[i + 1]:
                    best_score[i + 1] = cand
                    best_len[i + 1] = -1  # negative indicates byte fallback of norm[i]
            elif not matched_any and best_score[i + 1] == -math.inf:
                best_score[i + 1] = best_score[i] - 30.0
                best_len[i + 1] = -1

        # Backtrack
        spans: list[tuple[int, int]] = []
        pos = n
        while pos > 0:
            step = best_len[pos]
            if step > 0:
                start = pos - step
                spans.append((start, pos))
                pos = start
            else:
                spans.append((pos - 1, -1))
                pos -= 1
        spans.reverse()

        for start, end in spans:
            if end == -1:
                ch = norm[start]
                for b in ch.encode("utf-8"):
                    ids.append(piece_to_id.get(f"<0x{b:02X}>", unk_id))
            else:
                ids.append(piece_to_id.get(norm[start:end], unk_id))

    if append_eos:
        ids.append(eos_id)
    return ids


def unigram_decode_reference(
    ids: Iterable[int],
    vocab: list[list],
    skip_ids: set[int] = {0, 1, 2},
) -> str:
    """Decodes Unigram IDs including UTF-8 `<0xXX>` byte sequences back to `str`."""
    parts: list[str] = []
    byte_buf = bytearray()

    def flush_bytes() -> None:
        if byte_buf:
            parts.append(byte_buf.decode("utf-8", errors="replace"))
            byte_buf.clear()

    vocab_len = len(vocab)
    newline_id = next(
        (idx for idx, entry in enumerate(vocab) if entry[0] == "<0x0A>"),
        next((idx for idx, entry in enumerate(vocab) if entry[0] == "<extra_id_0>"), None),
    )
    for idx in ids:
        if idx in skip_ids or idx < 0 or idx >= vocab_len:
            continue
        if newline_id is not None and idx == newline_id:
            flush_bytes()
            parts.append("\n")
            continue
        piece = vocab[idx][0]
        if len(piece) == 6 and piece.startswith("<0x") and piece.endswith(">"):
            try:
                byte_buf.append(int(piece[3:5], 16))
                continue
            except ValueError:
                pass
        flush_bytes()
        parts.append(piece.replace("\u2581", " "))

    flush_bytes()
    text = "".join(parts)
    if text.startswith(" "):
        text = text[1:]
    # Strip dummy space injected after newline when encoding multi-line text
    return text.replace("\n ", "\n")


def build_pruned_piece_table(
    pieces_with_scores: list[tuple[str, float]],
    corpus_texts: list[str],
    target_vocab_size: int = 12000,
) -> dict:
    """Selects up to `target_vocab_size` pieces preserving specials, 256 bytes, & domain tokens."""
    total_src = len(pieces_with_scores)
    target_vocab_size = min(target_vocab_size, total_src)
    piece_to_old_id = {p: idx for idx, (p, _) in enumerate(pieces_with_scores)}

    # 1. Mandatory IDs 0, 1, 2
    selected_old_ids: list[int] = [0, 1, 2]
    selected_set = set(selected_old_ids)

    def add_piece(p: str) -> None:
        old_id = piece_to_old_id.get(p)
        if old_id is not None and old_id not in selected_set and len(selected_old_ids) < target_vocab_size:
            selected_set.add(old_id)
            selected_old_ids.append(old_id)

    # 2. Dedicated newline token (`<0x0A>` if byte-fallback exists, else `<extra_id_0>`) + byte fallback tokens
    if "<0x0A>" not in piece_to_old_id:
        add_piece("<extra_id_0>")
    for bt in _BYTE_TOKENS:
        add_piece(bt)

    # 3. Essential ASCII & domain tag tokens
    for tok in _DOMAIN_ESSENTIALS:
        add_piece(tok)
    for code in range(33, 127):
        ch = chr(code)
        add_piece(ch)
        add_piece("\u2581" + ch)

    # 4. Frequency count via unigram encoding over original full vocab
    full_vocab = [[p, float(s)] for p, s in pieces_with_scores]
    usage_counts: Counter[int] = Counter()
    for text in corpus_texts:
        for tid in unigram_encode_reference(text, full_vocab, append_eos=False):
            usage_counts[tid] += 1

    # Rank remaining pieces: corpus hits first, then higher Unigram log-prob (and Latin preference)
    remaining: list[tuple[float, int]] = []
    for old_id, (piece, score) in enumerate(pieces_with_scores):
        if old_id in selected_set:
            continue
        if piece.startswith("<extra_id_"):
            continue
        hits = usage_counts.get(old_id, 0)
        latin_bonus = 2.0 if piece.replace("\u2581", "").isascii() else 0.0
        rank_key = hits * 1000.0 + float(score) + latin_bonus
        remaining.append((rank_key, old_id))

    remaining.sort(key=lambda item: item[0], reverse=True)
    for _, old_id in remaining:
        if len(selected_old_ids) >= target_vocab_size:
            break
        selected_set.add(old_id)
        selected_old_ids.append(old_id)

    pruned_vocab = [[pieces_with_scores[oid][0], float(pieces_with_scores[oid][1])] for oid in selected_old_ids]
    return {
        "old_to_new_ids": selected_old_ids,
        "vocab": pruned_vocab,
        "pad_id": 0,
        "eos_id": 1,
        "unk_id": 2,
    }


def save_sp_vocab_json(pruned: dict, path: str) -> None:
    with open(path, "w", encoding="utf-8") as f:
        json.dump(pruned["vocab"], f, ensure_ascii=False, separators=(",", ":"))
