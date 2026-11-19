# Compact Seq2Seq Notice Parser (`Flan-T5-Small` Pruned) + `FoundationModels` Design Spec

> **Status**: Approved (Option A Tier Priority + Option A Field Scope)
> **Date**: 2026-11-19
> **Author**: Porage-Lover <jitund05@gmail.com>

---

## 1. Objective & Hard Constraints

Replace OneTake's bundled **304 MB** `Qwen2.5-0.5B` Core ML model (`OneTakeParserANE.mlpackage`) and **4.45 MB** Qwen BPE vocabulary files (`vocab.json`, `merges.txt`) with an ultra-compact, 100% native Core ML **Bidirectional Encoder-Decoder** (`Flan-T5-Small`, vocabulary-pruned & 4-bit quantized) paired with Apple Intelligence **`FoundationModels` (`@Generable`)** on iOS 26+.

| Constraint | Requirement |
| :--- | :--- |
| **Total On-Disk Footprint** (model + tokenizer assets) | **≤ 35 MB** (~29–33 MB target) |
| **Native Runtime** | 100% Apple `CoreML.framework` (`.all` compute units: ANE/GPU/CPU) + `FoundationModels` (iOS 26+) |
| **Zero External Runtimes** | No C/C++ inference frameworks (no Cactus CQ2, llama.cpp, or ONNX Runtime) |
| **Minimum OS & Hardware** | iOS 18.0+, **all iPhones including ≤4 GB RAM devices** (iPhone 11, 12, SE) |
| **RAM Safety Gate** | Lower `CoreMLParserRunner` minimum physical memory gate from `5_000_000_000` (5 GB) to `2_500_000_000` (2.5 GB), peak parser RAM < 120 MB |
| **End-to-End Inference Latency** | < 250 ms on Apple Neural Engine |
| **Extracted Fields (Scope: Option A)** | Focused 5 fields: `project`, `role`, `role_description`, `due_date`, `submission_email` (numeric slate/clip durations & headshot ratios stay in deterministic regex) |
| **Hallucination Protection** | Explicit `NONE` abstention + `OnDeviceIntelligence.isGroundedNoticeValue` source-grounding filter |
| **Core ML Author Metadata** | `Porage-Lover <jitund05@gmail.com>` |

---

## 2. Three-Tier Orchestration Architecture (Priority: Option A)

```
Casting Notice (Camera Scan / Image / PDF / DOCX / Pasted Text)
   │
   ▼
Tier 0: CastingCallParserService (Deterministic Regex + OCRLayoutReconstructor)
   │  └─ Handles explicit labels, mailto emails, slate/clip durations, headshot ratios, screenplay dialogue.
   │  └─ If all 4 core fields present (project, role, email, deadline) -> DONE.
   ▼
Tier 1: CoreMLParserRunner — Pruned Flan-T5-Small (~30 MB, 100% Offline, iOS 18+ All Devices)
   │  └─ Runs first whenever any of the 4 core fields is missing/default.
   │  └─ Emits tagged lines -> parsed & checked by isGroundedNoticeValue.
   ▼
Tier 2: Apple Intelligence FoundationModels (@Generable, 0 MB, iOS 26+ AI Devices Only)
   │  └─ Runs ONLY if Tier 0 + Tier 1 still leave a core field missing/ungrounded.
   │  └─ Typed @Generable GroundedCastingExtraction -> checked by isGroundedNoticeValue.
   ▼
ParsedCastingCall
```

### Decision Rationale
Running the domain-trained `Flan-T5-Small` model (Tier 1) ahead of `FoundationModels` (Tier 2) guarantees consistent, fast (~120 ms) parsing specialized on Indian and international casting calls across all iPhones, while still leveraging Apple's 3B system model as a semantic rescue on Apple Intelligence devices when notices use unusual implicit prose.

---

## 3. Model Sizing & Packaging Specification

Base model: `google/flan-t5-small` (8 encoder layers, 8 decoder layers, `d_model = 512`, `d_ff = 1024`, `num_heads = 6`, `d_kv = 64`, untied `shared.weight` and `lm_head.weight`).

### Vocabulary Surgery (`32,128` → `12,000` tokens)
* Retain: special/sentinel tokens (`<pad>`, `</s>`, `<unk>`), all **256 UTF-8 byte-fallback tokens** (`<0x00>`–`<0xFF>`) for lossless Unicode round-tripping (`–`, `—`, `₹`, Devanagari, curly quotes), ASCII digits/punctuation, and the highest-frequency English + Indian-English/Hinglish casting corpus tokens.
* Slice `shared.weight` and `lm_head.weight` rows to the exact 12,000 retained token IDs, remapping IDs contiguously `[0..<12000]`.

### Size Budget
* Encoder (8 layers, 18.88M params @ 4-bit blockwise `block_size=32`): **~10.4 MB**
* Decoder (8 layers, 25.17M params @ 4-bit blockwise `block_size=32`): **~13.8 MB**
* Shared Embeddings (`shared.weight`, 6.14M params @ 4-bit): **~3.4 MB**
* Output Head (`lm_head.weight`, 6.14M params @ 4-bit): **~3.4 MB**
* LayerNorms & Relative Position Biases (FP16): **~0.1 MB**
* Tokenizer Asset (`sp_vocab.json`, compact JSON array of `[piece, score]`): **~0.3 MB**
* **Total Bundled Footprint**: **~31.4 MB** (using iOS 18 Core ML multi-function `OneTakeParserANE.mlpackage` with `encode` + `decode` functions sharing `shared.weight`, OR two separate files `OneTakeParserEncoder.mlpackage` + `OneTakeParserDecoder.mlpackage` with 10,000 vocab totaling **~31.5 MB**).

---

## 4. Structured Output Contract

To avoid SentencePiece `{` / `}` byte-fallback inefficiency and quote-escaping brittleness, the Seq2Seq model emits strictly ordered, single-value tagged lines (max 96 output tokens):

```text
PROJECT: MCCC - KOSHISHE
ROLE: Male Lead
DESC: Male Lead for an upcoming Hindi theatrical feature film
DEADLINE: 15 December, 2026
EMAIL: abhinav@mcc.in
```

Rules:
1. Any absent or unstated field **must** emit literal `NONE` (e.g., `DEADLINE: NONE`).
2. Every non-`NONE` field is passed through `OnDeviceIntelligence.isGroundedNoticeValue(_:in:)` before updating `ParsedCastingCall`.
3. `OnDeviceIntelligence.parsePlainLines(_:sourceText:)` adds `DESC:` parsing for `roleDescription` alongside `PROJECT:`, `ROLE:`, `EMAIL:`, and `DEADLINE:`.
4. Dialogue sides attached after a casting notice are truncated/excluded by deterministic notice-prefix rules or handled during training so screenplay character names and dialogue dates never bleed into notice metadata.

---

## 5. Core ML Graph & Pure-Swift Runtime Interfaces

### 5.1 Core ML Graph
* **Format**: Core ML `mlprogram` targeting `iOS18`, FP16 internal compute precision, 4-bit linear blockwise weight quantization (`block_size=32`), compute units `.all`.
* **Encoder inputs/outputs**:
  * Inputs: `input_ids` (`Int32 [1, S]`), `attention_mask` (`Float16 [1, S]`) where `S ∈ {128, 256, 512}` (enumerated shapes).
  * Output: `encoder_hidden_states` (`Float16 [1, S, 512]`).
* **Decoder inputs/outputs**:
  * Primary: Single-token step `decoder_input_id` (`Int32 [1, 1]`), `encoder_hidden_states` (`Float16 [1, S, 512]`), `encoder_attention_mask` (`Float16 [1, S]`), `cache_position` (`Int32 [1]`) with iOS 18 `MLState` KV-cache (`self_k`, `self_v`, `cross_k`, `cross_v`).
  * Fallback if `MLState` tracing encounters CoreMLTools cross-attention limitations: static enumerated decoder sequence buckets `[32, 64, 96]` (total pass ~200–250 ms on ANE).

### 5.2 Pure-Swift `UnigramTokenizer` (`OneTake/Services/UnigramTokenizer.swift`)
* Thread-safe (`nonisolated final class UnigramTokenizer: @unchecked Sendable` with `NSLock`).
* Loads `sp_vocab.json` lazily on demand and supports `unload()`.
* Implements exact SentencePiece Unigram Viterbi DP segmentation (`▁` whitespace normalization, longest/highest-score path, `<0xXX>` UTF-8 byte fallback, ID `0` = `<pad>`, ID `1` = `</s>`, ID `2` = `<unk>`).
* Verified by a golden parity test against Python HuggingFace `T5Tokenizer`.

### 5.3 `OnDeviceIntelligence` (`@Generable` Tier 2 Rescue)
On `#if canImport(FoundationModels)` with `#available(iOS 26.0, *)`:
```swift
@Generable
struct GroundedCastingExtraction {
    @Guide(description: "Exact project or production title explicitly stated in the notice, or null if absent.")
    var project: String?
    @Guide(description: "Exact role or character breakdown sought, or null if absent.")
    var role: String?
    @Guide(description: "Concise grounded role requirements copied or condensed from the notice, or null if absent.")
    var roleDescription: String?
    @Guide(description: "Exact explicit submission deadline date/time string from the notice, or null if absent.")
    var dueDate: String?
    @Guide(description: "Submission email address for sending applications (prefer submission over general agency email), or null if absent.")
    var submissionEmail: String?
}
```

---

## 6. Colab Pro Training & Conversion Workflow

Implemented via modular Python scripts in `scripts/ml/` plus a self-contained Colab Pro notebook `scripts/colab/train_onetake_flan_t5_coreml.ipynb`:
1. **Synthetic + Hard-Negative Corpus Builder** (`18,000` train / `1,000` val / `1,000` test): Bollywood/Indian notices, US/UK breakdowns, WhatsApp prose, noisy multi-column OCR, dual-email traps (agency vs. submission), dual-date traps (shoot vs. deadline), missing-field abstention (`NONE`), and notices with trailing script sides. Every sample passes programmatic grounding verification before entering the dataset.
2. **Vocabulary Surgery & Tokenizer Export**: Prunes `google/flan-t5-small` to `12,000` pieces, slices embeddings + `lm_head`, and writes `sp_vocab.json` + golden parity vectors.
3. **Full Fine-Tuning + 4-Bit QAT**: Stage 1 (`bf16`, 4–5 epochs, cosine LR `3e-4`, label smoothing `0.05`); Stage 2 (fake 4-bit `block_size=32` QAT, 1 epoch, LR `5e-5`).
4. **Core ML Export & Local Parity Gate**: Exports quantized `.mlpackage` stamped with author `Porage-Lover <jitund05@gmail.com>`, verifies disk size ≤ 35 MB, and checks ≥ 95% F1 + 100% pass on `1.txt`, `1c.txt`, `2c.png`, and `3c.pdf`.

---

## 7. Verification Gates

1. **Bundle Size**: `OneTake/MLModels` parser model + `sp_vocab.json` ≤ **35 MB**.
2. **Tokenizer Parity**: 100% identical token IDs between Swift `UnigramTokenizer` and Python reference across 20 golden test notices.
3. **Held-out Eval & Real Fixtures**: ≥ 95% field F1, ≥ 98% `NONE` abstention accuracy on missing fields, 100% pass on real fixtures (`1.txt`, `1c.txt`, `2c.png`, `3c.pdf`, `MCCC - KOSHISHE`).
4. **iOS Build & Tests**: `xcodebuild build` (`generic/platform=iOS`) and full `OneTakeTests` suite passing on iOS Simulator and physical iPhone 17 Pro (<250 ms latency, <120 MB peak delta).
