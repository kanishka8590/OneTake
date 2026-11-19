import unittest
from dataset_generator import (
    format_tagged_target,
    generate_casting_corpus,
    is_grounded_notice_value,
)


class TestDatasetGenerator(unittest.TestCase):
    def test_grounding_matches_swift_rule(self):
        src = "MCCC - KOSHISHE\nRole: Male Lead\nEmail: abhinav@mcc.in\n"
        self.assertTrue(is_grounded_notice_value("MCCC - KOSHISHE", src))
        self.assertTrue(is_grounded_notice_value("abhinav@mcc.in", src))
        self.assertTrue(is_grounded_notice_value("Male Lead", src))
        self.assertFalse(is_grounded_notice_value("fabricated@other.com", src))
        self.assertFalse(is_grounded_notice_value("NONE", src))

    def test_tagged_target_formats_none_cleanly(self):
        out = format_tagged_target(
            project="Photon",
            role=None,
            desc="Fresh male talent 22-25",
            deadline=None,
            email="cast@drama.com",
        )
        self.assertEqual(
            out,
            "PROJECT: Photon\nROLE: NONE\nDESC: Fresh male talent 22-25\nDEADLINE: NONE\nEMAIL: cast@drama.com",
        )

    def test_corpus_covers_traps_and_passes_grounding(self):
        splits = generate_casting_corpus(num_train=240, num_val=60, num_test=60, seed=42)
        self.assertEqual(len(splits["train"]), 240)
        self.assertEqual(len(splits["val"]), 60)
        self.assertEqual(len(splits["test"]), 60)

        categories = {row["category"] for row in splits["train"]}
        expected_categories = {
            "standard_labeled",
            "dual_email_trap",
            "dual_date_trap",
            "missing_fields",
            "whatsapp_prose",
            "trailing_sides",
            "noisy_ocr",
        }
        self.assertTrue(expected_categories.issubset(categories))

        for split_name, rows in splits.items():
            for idx, row in enumerate(rows):
                lines = row["target"].splitlines()
                self.assertEqual(len(lines), 5, f"{split_name}[{idx}] bad target: {row['target']}")
                prefixes = [line.split(":", 1)[0] for line in lines]
                self.assertEqual(prefixes, ["PROJECT", "ROLE", "DESC", "DEADLINE", "EMAIL"])
                for line in lines:
                    key, val = line.split(":", 1)
                    val = val.strip()
                    if val != "NONE":
                        self.assertTrue(
                            is_grounded_notice_value(val, row["input"]),
                            f"Ungrounded {key}={val!r} in {row['category']}:\n{row['input']}",
                        )


if __name__ == "__main__":
    unittest.main()
