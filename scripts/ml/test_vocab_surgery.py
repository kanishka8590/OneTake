import unittest
from vocab_surgery import (
    build_pruned_piece_table,
    unigram_decode_reference,
    unigram_encode_reference,
)


class TestVocabSurgery(unittest.TestCase):
    def test_pruning_preserves_specials_and_all_256_byte_tokens(self):
        mock_pieces = [("<pad>", 0.0), ("</s>", 0.0), ("<unk>", 0.0)]
        mock_pieces += [(f"<0x{b:02X}>", -20.0) for b in range(256)]
        mock_pieces += [(f"\u2581word{i}", -float((i % 10) + 1)) for i in range(500)]
        mock_pieces += [(f"\u2581unused_{i}", -8.0) for i in range(100)]
        corpus = ["PROJECT: word1 word2", "ROLE: word3 \u2013 Mumbai \u20b95000"]

        res = build_pruned_piece_table(mock_pieces, corpus, target_vocab_size=400)
        vocab = res["vocab"]
        self.assertEqual(len(vocab), 400)
        self.assertEqual(vocab[0][0], "<pad>")
        self.assertEqual(vocab[1][0], "</s>")
        self.assertEqual(vocab[2][0], "<unk>")
        pieces_set = {p for p, _ in vocab}
        for b in range(256):
            self.assertIn(f"<0x{b:02X}>", pieces_set)
        self.assertIn("\u2581word1", pieces_set)
        self.assertIn("\u2581word2", pieces_set)
        self.assertEqual(len(res["old_to_new_ids"]), 400)

    def test_reference_viterbi_round_trips_unicode_losslessly(self):
        mock_pieces = [("<pad>", 0.0), ("</s>", 0.0), ("<unk>", 0.0)]
        mock_pieces += [(f"<0x{b:02X}>", -20.0) for b in range(256)]
        mock_pieces += [
            ("\u2581", -2.5),
            ("\u2581PROJECT", -1.5),
            (":", -1.0),
            ("\u2581Male", -1.8),
            ("\u2581Lead", -1.9),
        ]
        res = build_pruned_piece_table(mock_pieces, ["PROJECT: Male Lead"], target_vocab_size=264)
        sample = "PROJECT: Male Lead \u2013 \u20b95000 हिन्दी\nabhinav@mcc.in"
        expected = "PROJECT: Male Lead - Rs.5000 हिन्दी\nabhinav@mcc.in"
        ids = unigram_encode_reference(sample, res["vocab"])
        self.assertEqual(ids[-1], 1)  # EOS token
        decoded = unigram_decode_reference(ids, res["vocab"])
        self.assertEqual(decoded, expected)

    def test_flan_t5_non_byte_vocab_uses_extra_id_0_for_newlines(self):
        mock_pieces = [("<pad>", 0.0), ("</s>", 0.0), ("<unk>", 0.0)]
        mock_pieces += [(ch, -1.5) for ch in ["P", "R", "O", "J", "E", "C", "T", "L", "D", "A", "I", "M", "N", "2", "0", "5", ":", "-", ".", "@", "\u2581"]]
        mock_pieces += [
            ("\u2581PROJECT", -1.2),
            ("\u2581ROLE", -1.2),
            ("\u2581DESC", -1.2),
            ("\u2581DEADLINE", -1.2),
            ("\u2581EMAIL", -1.2),
            ("\u2581Male", -1.4),
            ("\u2581Lead", -1.4),
            ("\u258120", -1.4),
            ("25", -1.4),
            ("\u2581NONE", -1.4),
            ("<extra_id_0>", -10.0),
            ("<extra_id_1>", -10.0),
        ]
        res = build_pruned_piece_table(mock_pieces, ["PROJECT: Male Lead"], target_vocab_size=35)
        pieces_set = {p for p, _ in res["vocab"]}
        self.assertIn("<extra_id_0>", pieces_set)
        self.assertNotIn("<extra_id_1>", pieces_set)

        tagged = "PROJECT: Male\nROLE: Lead\nDESC: 20\u201325\nDEADLINE: NONE\nEMAIL: NONE"
        ids = unigram_encode_reference(tagged, res["vocab"])
        self.assertNotIn(2, ids)  # Zero <unk> collisions on newline or en-dash
        decoded = unigram_decode_reference(ids, res["vocab"])
        self.assertEqual(decoded, "PROJECT: Male\nROLE: Lead\nDESC: 20-25\nDEADLINE: NONE\nEMAIL: NONE")


if __name__ == "__main__":
    unittest.main()
