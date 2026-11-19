# Compact Seq2Seq Notice Parser (`Flan-T5-Small` Pruned) + `FoundationModels` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace OneTake's 304 MB Qwen2.5-0.5B parser with a ≤35 MB vocabulary-pruned, 4-bit quantized `Flan-T5-Small` Core ML Seq2Seq model paired with iOS 26+ `FoundationModels` (`@Generable`) Tier 2 semantic rescue.

**Architecture:** Deterministic regex/spatial parsing (Tier 0) feeds `OnDeviceIntelligence`, which calls `CoreMLParserRunner` running a pruned 12k-vocab `Flan-T5-Small` Seq2Seq model via pure-Swift `UnigramTokenizer` (Tier 1, 100% offline on iOS 18+ devices ≥2.5 GB RAM), and rescues any still-missing fields using `FoundationModels` `@Generable` on iOS 26+ (Tier 2). Training, vocabulary surgery, and 4-bit QAT run in Python / Colab Pro (`scripts/colab/train_onetake_flan_t5_coreml.ipynb`), outputting Core ML `.mlpackage` + `sp_vocab.json` for `OneTake/MLModels/`.

**Tech Stack:** Swift 5 (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`), Core ML (`iOS18` `mlprogram`, `MLState`), `FoundationModels` (`@Generable`), Python 3 (PyTorch, HuggingFace `transformers`, `sentencepiece`, `coremltools`), Colab Pro (A100/L4).

**Spec:** [2026-11-19-compact-seq2seq-parser-design.md](file:///Users/user36/Documents/Projects/OneTake/docs/superpowers/specs/2026-11-19-compact-seq2seq-parser-design.md)

## Global Constraints

- Total parser bundle footprint (`OneTake/MLModels/` parser `.mlpackage` + `sp_vocab.json`) ≤ **35 MB**.
- Zero third-party C/C++ inference libraries; 100% Apple `CoreML.framework` (`.all` compute units) + `FoundationModels`.
- Minimum iOS deployment target: **iOS 18.0**; RAM gate in `CoreMLParserRunner.supportsInProcessParserModel`: **`2_500_000_000`** bytes (2.5 GB).
- Core ML model author metadata: **`Porage-Lover <jitund05@gmail.com>`**.
- Focused 5 extracted fields (Option A Scope): `project`, `role`, `role_description`, `due_date`, `submission_email`.
- Tier priority (Option A): Tier 0 (`CastingCallParserService`) → Tier 1 (`CoreMLParserRunner`) → Tier 2 (`FoundationModels` `@Generable` only for remaining empty/ungrounded fields).
- Every neural field must pass `OnDeviceIntelligence.isGroundedNoticeValue(_:in:)` before mutating `ParsedCastingCall`.
- Preserve existing unrelated uncommitted edits in `OneTake.xcodeproj/project.xcproj`.

## Review Focus

- Unicode & OCR noise (`–`, `—`, `₹`, curly quotes, Devanagari, whitespace runs) causing `<unk>` tokens or Python-vs-Swift tokenizer ID drift → pinned by UTF-8 round-trip & golden parity tests in Task 2 and Task 4.
- Dual-email & dual-date traps (agency email vs submission email, shoot date vs deadline) plus appended screenplay dialogue sides bleeding into metadata → pinned by adversarial fixture generation tests in Task 1 and parser tests in Task 5 & Task 6.
- Missing fields in notices without deadlines or emails generating hallucinated values instead of `NONE` → pinned by abstention tests in Task 1, Task 5, and Task 6.
- Tagged-line values containing colons or Tier 2 `@Generable` overwriting grounded Tier 0/1 values → pinned by line parser & priority orchestration tests in Task 5.
- Low-RAM device gate & bundle size cap (>35 MB regression or Jetsam block on 4 GB devices) → pinned by footprint check and memory-gate tests in Task 3 and Task 7.

---

### Task 1: Casting Corpus Generator & Grounding Validator

**Files:**
- Create: `scripts/ml/dataset_generator.py`
- Test: `scripts/ml/test_dataset_generator.py`

**Interfaces:**
- Produces:
  - `is_grounded_notice_value(value: str, source: str) -> bool`
  - `format_tagged_target(project: str | None, role: str | None, desc: str | None, deadline: str | None, email: str | None) -> str`
  - `generate_casting_corpus(num_train: int, num_val: int, num_test: int, seed: int = 42) -> dict[str, list[dict[str, str]]]`

- [ ] **Step 1: Write the failing test**

```python
# scripts/ml/test_dataset_generator.py
import unittest
from dataset_generator import is_grounded_notice_value, format_tagged_target, generate_casting_corpus

class TestDatasetGenerator(unittest.TestCase):
    def test_grounding_matches_swift_rule(self):
        src = "MCCC - KOSHISHE\nRole: Male Lead\nEmail: abhinav@mcc.in\n"
        self.assertTrue(is_grounded_notice_value("MCCC - KOSHISHE", src))
        self.assertTrue(is_grounded_notice_value("abhinav@mcc.in", src))
        self.assertFalse(is_grounded_notice_value("fabricated@other.com", src))

    def test_tagged_target_formats_none_cleanly(self):
        out = format_tagged_target("Photon", None, "Fresh male talent 22-25", None, "cast@drama.com")
        self.assertEqual(
            out,
            "PROJECT: Photon\nROLE: NONE\nDESC: Fresh male talent 22-25\nDEADLINE: NONE\nEMAIL: cast@drama.com"
        )

    def test_corpus_covers_traps_and_passes_grounding(self):
        splits = generate_casting_corpus(num_train=200, num_val=40, num_test=40, seed=42)
        self.assertEqual(len(splits["train"]), 200)
        self.assertEqual(len(splits["val"]), 40)
        categories = {row["category"] for row in splits["train"]}
        self.assertTrue({"dual_email_trap", "dual_date_trap", "missing_fields", "whatsapp_prose", "trailing_sides"}.issubset(categories))
        for split_rows in splits.values():
            for row in split_rows:
                for line in row["target"].splitlines():
                    key, val = line.split(":", 1)
                    val = val.strip()
                    if val != "NONE":
                        self.assertTrue(is_grounded_notice_value(val, row["input"]), f"Ungrounded {key}={val}")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python3 -m unittest scripts/ml/test_dataset_generator.py -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'dataset_generator'`

- [ ] **Step 3: Implement `scripts/ml/dataset_generator.py`**

Implement `is_grounded_notice_value` matching `OnDeviceIntelligence.isGroundedNoticeValue` (verbatim case/diacritic-insensitive substring OR ≥75% alphanumeric word overlap), `format_tagged_target`, and template/combinatorial generators producing diverse Indian, US/UK, Hinglish-Latin, OCR-noisy, multi-column, WhatsApp prose, dual-email trap, dual-date trap, missing-field (`NONE`), and trailing screenplay sides samples. Include the real phrasing patterns from `1.txt`, `1c.txt`, `2c.png`, and `3c.pdf` variations (keeping held-out validation independent).

- [ ] **Step 4: Run test to verify it passes**

Run: `python3 -m unittest scripts/ml/test_dataset_generator.py -v`
Expected: PASS (3 tests)

- [ ] **Step 5: Commit**

```bash
git add scripts/ml/dataset_generator.py scripts/ml/test_dataset_generator.py
git commit -m "feat(ml): add casting notice corpus generator and grounding validator"
```

---

### Task 2: Vocabulary Surgery & Pure-JSON Unigram Asset Exporter

**Files:**
- Create: `scripts/ml/vocab_surgery.py`
- Test: `scripts/ml/test_vocab_surgery.py`

**Interfaces:**
- Consumes: `generate_casting_corpus` from Task 1.
- Produces:
  - `build_pruned_piece_table(pieces_with_scores: list[tuple[str, float]], corpus_texts: list[str], target_vocab_size: int = 12000) -> dict` returning `{"old_to_new_ids": list[int], "vocab": list[list], "pad_id": 0, "eos_id": 1, "unk_id": 2}`
  - `unigram_encode_reference(text: str, vocab: list[list], unk_id: int = 2) -> list[int]`
  - `unigram_decode_reference(ids: list[int], vocab: list[list], skip_ids: set[int] = {0, 1, 2}) -> str`

- [ ] **Step 1: Write the failing test**

```python
# scripts/ml/test_vocab_surgery.py
import unittest
from vocab_surgery import build_pruned_piece_table, unigram_encode_reference, unigram_decode_reference

class TestVocabSurgery(unittest.TestCase):
    def test_pruning_preserves_specials_and_all_256_byte_tokens(self):
        mock_pieces = [("<pad>", 0.0), ("</s>", 0.0), ("<unk>", 0.0)]
        mock_pieces += [(f"<0x{b:02X}>", -20.0) for b in range(256)]
        mock_pieces += [(f"▁word{i}", -float(i % 10 + 1)) for i in range(500)]
        mock_pieces += [("▁unused_ru", -3.0) for _ in range(100)]
        corpus = ["PROJECT: word1 word2", "ROLE: word3 – Mumbai ₹5000"]
        res = build_pruned_piece_table(mock_pieces, corpus, target_vocab_size=400)
        vocab = res["vocab"]
        self.assertEqual(len(vocab), 400)
        self.assertEqual(vocab[0][0], "<pad>")
        self.assertEqual(vocab[1][0], "</s>")
        self.assertEqual(vocab[2][0], "<unk>")
        pieces_set = {p for p, _ in vocab}
        for b in range(256):
            self.assertIn(f"<0x{b:02X}>", pieces_set)

    def test_reference_viterbi_round_trips_unicode_losslessly(self):
        mock_pieces = [("<pad>", 0.0), ("</s>", 0.0), ("<unk>", 0.0)]
        mock_pieces += [(f"<0x{b:02X}>", -20.0) for b in range(256)]
        mock_pieces += [("▁PROJECT", -1.5), (":", -1.0), ("▁Male", -1.8), ("▁Lead", -1.9)]
        res = build_pruned_piece_table(mock_pieces, ["PROJECT: Male Lead"], target_vocab_size=263)
        sample = "PROJECT: Male Lead – ₹5000\nabhinav@mcc.in"
        ids = unigram_encode_reference(sample, res["vocab"])
        self.assertEqual(unigram_decode_reference(ids, res["vocab"]), sample)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python3 -m unittest scripts/ml/test_vocab_surgery.py -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'vocab_surgery'`

- [ ] **Step 3: Implement `scripts/ml/vocab_surgery.py`**

Implement `build_pruned_piece_table` retaining `<pad>` (0), `</s>` (1), `<unk>` (2), all 256 `<0xXX>` byte-fallback tokens, single-character ASCII/printable tokens + tag prefixes (`PROJECT`, `ROLE`, `DESC`, `DEADLINE`, `EMAIL`, `NONE`), plus top tokens ranked by corpus occurrence & pretrained Unigram frequency up to `target_vocab_size`. Implement `unigram_encode_reference` (SentencePiece `▁` space normalization + exact Viterbi DP over the piece trie + UTF-8 byte fallback) and `unigram_decode_reference` (accumulating `<0xXX>` sequences into UTF-8 bytes and replacing `▁` with space, matching SentencePiece behavior).

- [ ] **Step 4: Run test to verify it passes**

Run: `python3 -m unittest scripts/ml/test_vocab_surgery.py -v`
Expected: PASS (2 tests)

- [ ] **Step 5: Commit**

```bash
git add scripts/ml/vocab_surgery.py scripts/ml/test_vocab_surgery.py
git commit -m "feat(ml): add Flan-T5 vocabulary surgery and Unigram Viterbi reference"
```

---

### Task 3: Colab Pro Training, QAT & Core ML Export Pipeline

**Files:**
- Create: `scripts/ml/train_and_qat.py`
- Create: `scripts/ml/export_coreml.py`
- Create: `scripts/colab/train_onetake_flan_t5_coreml.ipynb`
- Test: `scripts/ml/test_export_wrappers.py`

**Interfaces:**
- Consumes: `generate_casting_corpus` (Task 1), `build_pruned_piece_table` / `unigram_encode_reference` (Task 2).
- Produces:
  - `T5EncoderWrapper(nn.Module)` (`input_ids: [1, S], attention_mask: [1, S]` → `encoder_hidden_states: [1, S, 512]`)
  - `T5DecoderStepWrapper(nn.Module)` (`decoder_input_ids: [1, K], encoder_hidden_states: [1, S, 512], encoder_attention_mask: [1, S]` → `logits: [1, K, V]`, plus optional `MLState` stateful wrapper)
  - `export_coreml_models(checkpoint_dir: str, output_dir: str, author: str = "Porage-Lover <jitund05@gmail.com>") -> dict` validating total size ≤ 35 MB.
  - Self-contained Colab Pro notebook `scripts/colab/train_onetake_flan_t5_coreml.ipynb` that installs deps, runs dataset generation → vocab surgery → Stage 1 bf16 full fine-tune → Stage 2 fake 4-bit blockwise QAT → Core ML 4-bit export → prints exact F1 & size checks → zips `OneTakeParserANE.mlpackage` (or Encoder/Decoder pair) + `sp_vocab.json` + `golden_parity_vectors.json` for download.

- [ ] **Step 1: Write test for PyTorch graph wrappers & metadata contract (CPU-only mock check)**

Write `scripts/ml/test_export_wrappers.py` asserting that `T5EncoderWrapper` and `T5DecoderStepWrapper` trace cleanly with tiny dummy `T5Config(vocab_size=300, d_model=64, d_ff=128, num_layers=2, num_heads=2)` via `torch.jit.trace` when `torch` is installed (skipping cleanly with unittest skip if torch isn't accessible in sandbox).

- [ ] **Step 2: Implement `scripts/ml/train_and_qat.py`, `scripts/ml/export_coreml.py`, and `scripts/colab/train_onetake_flan_t5_coreml.ipynb`**

Implement:
- `train_and_qat.py`: HuggingFace `T5ForConditionalGeneration.from_pretrained("google/flan-t5-small")` vocab pruning (`resize_token_embeddings` / manual slice of `shared`, `encoder.embed_tokens`, `decoder.embed_tokens`, `lm_head`), Stage 1 cosine fine-tune (`epochs=5, lr=3e-4, label_smoothing=0.05`), Stage 2 fake 4-bit blockwise `block_size=32` QAT (`epochs=1, lr=5e-5`), held-out F1 + abstention evaluator.
- `export_coreml.py`: PyTorch tracing + `coremltools.convert` (`mlprogram`, `iOS18`, FP16 precision, enumerated shapes `[128, 256, 512]` encoder & `[1..96]` / `MLState` decoder), 4-bit `OptimizationConfig(op_config=OpLinearQuantizerConfig(mode="linear_symmetric", dtype="int4", granularity="per_block", block_size=32))`, `Porage-Lover <jitund05@gmail.com>` metadata stamp, and `<= 35 MB` assertion.
- `scripts/colab/train_onetake_flan_t5_coreml.ipynb`: Clean notebook wrapping Steps 1–4 for one-click Colab Pro A100/L4 execution.

- [ ] **Step 3: Validate Python scripts syntax & wrapper tests**

Run: `python3 -m py_compile scripts/ml/train_and_qat.py scripts/ml/export_coreml.py scripts/ml/test_export_wrappers.py && python3 -c "import json; nb=json.load(open('scripts/colab/train_onetake_flan_t5_coreml.ipynb')); assert len(nb['cells']) >= 6"`
Expected: Exit code 0.

- [ ] **Step 4: Commit**

```bash
git add scripts/ml/train_and_qat.py scripts/ml/export_coreml.py scripts/ml/test_export_wrappers.py scripts/colab/train_onetake_flan_t5_coreml.ipynb
git commit -m "feat(ml): add Flan-T5 fine-tuning, 4-bit QAT, Core ML export, and Colab Pro notebook"
```

---

### Task 4: Pure-Swift `UnigramTokenizer`

**Files:**
- Create: `OneTake/Services/UnigramTokenizer.swift`
- Modify: `OneTakeTests/CoreMLModelsTests.swift`

**Interfaces:**
- Produces in `OneTake/Services/UnigramTokenizer.swift`:
  - `nonisolated final class UnigramTokenizer: @unchecked Sendable`
  - `static let shared: UnigramTokenizer`
  - `let padTokenID: Int = 0`
  - `let eosTokenID: Int = 1`
  - `let unkTokenID: Int = 2`
  - `init(pieces: [(piece: String, score: Double)] = [])`
  - `var hasFullVocab: Bool`
  - `func loadIfNeeded()`
  - `func unload()`
  - `func encode(text: String, appendEOS: Bool = true) -> [Int]`
  - `func decode(tokens: [Int], skipSpecialTokens: Bool = true) -> String`

- [ ] **Step 1: Write failing unit tests in `OneTakeTests/CoreMLModelsTests.swift`**

Add tests `testUnigramTokenizerViterbiAndUTF8ByteFallback()` (constructing an in-memory piece table with `<pad>`, `</s>`, `<unk>`, `<0x00>`..`<0xFF>`, plus domain words, testing exact Viterbi scoring, UTF-8 byte fallback on `–`, `₹`, Devanagari `हिन्दी`, smart quotes, and `appendEOS: true` ending in `1`) and `testUnigramTokenizerUnloadResetsMemoryState()`.

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme OneTakeTests -destination 'platform=iOS Simulator,id=CE7ACC1D-6475-4A8F-BE6E-A206FA5C1757' -only-testing:OneTakeTests/CoreMLModelsTests/testUnigramTokenizerViterbiAndUTF8ByteFallback`
Expected: Build failure (`cannot find 'UnigramTokenizer' in scope`).

- [ ] **Step 3: Implement `OneTake/Services/UnigramTokenizer.swift`**

Implement `UnigramTokenizer` reading `sp_vocab.json` (array of `[piece, score]`), prefixing leading spaces with `▁` (`\u{2581}`) and normalizing internal whitespace runs/spaces to `▁`, running Viterbi DP over Unicode scalar slices using a prefix length cap + piece dictionary, falling back to `<0xXX>` UTF-8 byte tokens for uncovered characters, and decoding byte runs back to `String` via UTF-8 `Data`. Ensure `nonisolated` declarations throughout for `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -scheme OneTakeTests -destination 'platform=iOS Simulator,id=CE7ACC1D-6475-4A8F-BE6E-A206FA5C1757' -only-testing:OneTakeTests/CoreMLModelsTests/testUnigramTokenizerViterbiAndUTF8ByteFallback`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add OneTake/Services/UnigramTokenizer.swift OneTakeTests/CoreMLModelsTests.swift
git commit -m "feat(ml): implement pure-Swift SentencePiece UnigramTokenizer with UTF-8 byte fallback"
```

---

### Task 5: `OnDeviceIntelligence` Three-Tier Priority (Option A), `DESC:` Parsing & `@Generable` `FoundationModels`

**Files:**
- Modify: `OneTake/Services/OnDeviceIntelligence.swift`
- Modify: `OneTakeTests/CoreMLModelsTests.swift`

**Interfaces:**
- Modifies in `OneTake/Services/OnDeviceIntelligence.swift`:
  - `parsePlainLines(_ answer: String, sourceText: String) -> GroundedNoticeFields?` (adds `DESC:` support, handles colons inside values, ignores `NONE`/`none`/`null`)
  - `@available(iOS 26.0, *) @Generable struct GroundedCastingExtraction` (inside `#if canImport(FoundationModels)`)
  - `refineParsedCall(_ parsed: ParsedCastingCall, sourceText: String)` + helper `mergeGroundedFields(_:into:needsProject:needsRole:needsEmail:needsDeadline:sourceText:)` so Tier 1 runs first, and Tier 2 (`FoundationModels`) runs ONLY when any of `projectName`, `roleName`, `recipientEmail`, or `hasDetectedDeadline` remains unpopulated after Tier 1.

- [ ] **Step 1: Write failing tests in `OneTakeTests/CoreMLModelsTests.swift`**

Add tests:
- `testOnDeviceIntelligenceParsePlainLinesExtractsDescAndHandlesNoneAndColons()`: feeds tagged output `PROJECT: MCCC - KOSHISHE\nROLE: Male Lead\nDESC: 20-25 yrs, Hindi & English: Lead\nDEADLINE: NONE\nEMAIL: abhinav@mcc.in` and asserts `projectName`, `roleName`, `roleDescription` preserves `: Lead`, `recipientEmail`, and `deadline == nil`.
- `testOnDeviceIntelligenceTierPriorityDoesNotOverwriteGroundedFields()`: injects/tests merging logic verifying grounded Tier 0/1 fields are preserved and only still-missing fields accept Tier 2 updates when grounded.

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme OneTakeTests -destination 'platform=iOS Simulator,id=CE7ACC1D-6475-4A8F-BE6E-A206FA5C1757' -only-testing:OneTakeTests/CoreMLModelsTests/testOnDeviceIntelligenceParsePlainLinesExtractsDescAndHandlesNoneAndColons`
Expected: FAIL (`parsePlainLines` doesn't parse `DESC:` yet).

- [ ] **Step 3: Update `OneTake/Services/OnDeviceIntelligence.swift`**

Implement:
- `internal static func parsePlainLines(_ answer: String, sourceText: String) -> GroundedNoticeFields?` supporting `PROJECT:`, `ROLE:`, `DESC:`, `DEADLINE:`, `EMAIL:`, normalizing `"none"`/`"null"`/`"n/a"` to nil.
- `internal static func apply(_ fields: GroundedNoticeFields, to call: ParsedCastingCall, sourceText: String) -> ParsedCastingCall` gating each field on missing/default status + `isGroundedNoticeValue`.
- `#if canImport(FoundationModels)` `@available(iOS 26.0, *)` `@Generable` `GroundedCastingExtraction` using `session.respond(to: prompt, generating: GroundedCastingExtraction.self)`.
- Option A 3-tier execution in `refineParsedCall`: check if any field needed → run Tier 1 (`CoreMLParserRunner`) + apply grounded fields → recompute whether any core field is still needed → if still needed, run Tier 2 (`FoundationModels`) + apply grounded fields. (Keep support for tagged-line output OR JSON from `CoreMLParserRunner` cleanly.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -scheme OneTakeTests -destination 'platform=iOS Simulator,id=CE7ACC1D-6475-4A8F-BE6E-A206FA5C1757' -only-testing:OneTakeTests/CoreMLModelsTests`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add OneTake/Services/OnDeviceIntelligence.swift OneTakeTests/CoreMLModelsTests.swift
git commit -m "feat(intelligence): add @Generable FoundationModels rescue, DESC parsing, and 3-tier Option A priority"
```

---

### Task 6: `CoreMLParserRunner` Seq2Seq (`Flan-T5` + `MLState`) Pipeline Upgrade

**Files:**
- Modify: `OneTake/Services/CoreMLParserRunner.swift`
- Modify: `OneTakeTests/CoreMLModelsTests.swift`

**Interfaces:**
- Modifies in `OneTake/Services/CoreMLParserRunner.swift`:
  - `supportsInProcessParserModel`: `ProcessInfo.processInfo.physicalMemory >= 2_500_000_000` (enables 4 GB RAM iPhones like iPhone 11/12/SE)
  - `loadModelIfNeeded(allowSimulator: Bool = false)`: configures `MLModelConfiguration` with `computeUnits = .all` for Seq2Seq (`encoder_hidden_states` / multi-function `encode`+`decode` or `OneTakeParserEncoder` + `OneTakeParserDecoder`) and supports graceful inspection of input schema.
  - `generate(systemPrompt: String = ..., userPrompt: String, maxNewTokens: Int = 96, ...) async -> String?`: encodes notice with `UnigramTokenizer.shared` (Seq2Seq mode) into `[128, 256, 512]` padded bucket → runs Encoder once → runs Decoder autoregressively using `MLState` (if stateful) or bucketed `decoder_input_ids` until `eosTokenID (1)` or `maxNewTokens` → returns decoded tagged lines.

- [ ] **Step 1: Write test pinning RAM threshold & Seq2Seq interface compatibility**

Add `testCoreMLParserRunnerSupports4GBDevicesAndSeq2SeqPrompt()` in `OneTakeTests/CoreMLModelsTests.swift` asserting `CoreMLParserRunner.minimumSupportedPhysicalMemoryBytes == 2_500_000_000`.

- [ ] **Step 2: Update `OneTake/Services/CoreMLParserRunner.swift`**

Implement Seq2Seq loading (`OneTakeParserANE` multi-function `encode`/`decode`, or separate `OneTakeParserEncoder` + `OneTakeParserDecoder`), `MLState` KV-cache decoder loop + bucketed decoder fallback, `.all` compute units, `2_500_000_000` memory floor, and keep clean `unloadModel()` releasing encoder, decoder, and `UnigramTokenizer.shared.unload()`. Keep legacy single-model `input_ids` path intact ONLY until Task 7 removes the 304 MB Qwen `.mlpackage`, so existing tests stay green in the meantime!

- [ ] **Step 3: Run tests to verify they pass**

Run: `xcodebuild test -scheme OneTakeTests -destination 'platform=iOS Simulator,id=CE7ACC1D-6475-4A8F-BE6E-A206FA5C1757' -only-testing:OneTakeTests/CoreMLModelsTests`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add OneTake/Services/CoreMLParserRunner.swift OneTakeTests/CoreMLModelsTests.swift
git commit -m "feat(ml): upgrade CoreMLParserRunner for Seq2Seq ANE/MLState inference and 2.5GB RAM gate"
```

---

### Task 7: Bundle Swap (`≤35 MB`), Legacy Qwen Removal & Physical Device Verification *(After Colab Pro Export)*

**Files:**
- Delete: `OneTake/MLModels/OneTakeParserANE.mlpackage`, `OneTake/MLModels/vocab.json`, `OneTake/MLModels/merges.txt`, `OneTake/Services/BPETokenizer.swift`
- Add: `OneTake/MLModels/OneTakeParserANE.mlpackage` *(or Encoder/Decoder pair)*, `OneTake/MLModels/sp_vocab.json`
- Modify: `OneTake/Services/CoreMLParserRunner.swift` (remove legacy Qwen branch)
- Modify: `OneTakeTests/CoreMLModelsTests.swift` (add golden parity test, real fixture Seq2Seq extraction tests for `1.txt`, `1c.txt`, `MCCC - KOSHISHE`, abstention test, ≤35 MB bundle assertion)
- Modify: `ARCHITECTURE.md` (update Subsystem A diagram & footprint specs)

- [ ] **Step 1: Run Colab Pro notebook `scripts/colab/train_onetake_flan_t5_coreml.ipynb` and install generated assets into `OneTake/MLModels/`**
- [ ] **Step 2: Verify `du -sh OneTake/MLModels/` parser assets ≤ 35 MB**
- [ ] **Step 3: Remove legacy Qwen files (`vocab.json`, `merges.txt`, `BPETokenizer.swift`) and legacy branch in `CoreMLParserRunner.swift`**
- [ ] **Step 4: Update `OneTakeTests/CoreMLModelsTests.swift` with golden tokenizer parity vectors & full fixture tests**
- [ ] **Step 5: Run `xcodebuild build` (`generic/platform=iOS`) and full `OneTakeTests` suite on Simulator + physical iPhone 17 Pro; update `ARCHITECTURE.md`; commit**
