import json
import os
import tempfile
import unittest
import zipfile

from install_bundle import install_bundle


class TestInstallBundle(unittest.TestCase):
    def test_install_bundle_replaces_legacy_and_checks_size(self):
        with tempfile.TemporaryDirectory() as root:
            ml_dir = os.path.join(root, "OneTake", "MLModels")
            fixtures_dir = os.path.join(root, "OneTakeTests", "TestFixtures")
            os.makedirs(ml_dir)
            os.makedirs(fixtures_dir)
            # Create legacy files
            with open(os.path.join(ml_dir, "vocab.json"), "w") as f:
                f.write("{}")
            with open(os.path.join(ml_dir, "merges.txt"), "w") as f:
                f.write("#v")

            src_dir = os.path.join(root, "src")
            pkg_dir = os.path.join(src_dir, "OneTakeParserANE.mlpackage")
            os.makedirs(pkg_dir)
            with open(os.path.join(pkg_dir, "Manifest.json"), "w") as f:
                f.write("{}")
            with open(os.path.join(src_dir, "sp_vocab.json"), "w") as f:
                json.dump([["<pad>", 0.0], ["</s>", 0.0], ["<unk>", 0.0]], f)
            with open(os.path.join(src_dir, "golden_parity_vectors.json"), "w") as f:
                json.dump([{"text": "hi", "ids": [1]}], f)

            zip_path = os.path.join(root, "bundle.zip")
            with zipfile.ZipFile(zip_path, "w") as zf:
                for folder, _, files in os.walk(src_dir):
                    for fn in files:
                        full = os.path.join(folder, fn)
                        zf.write(full, os.path.relpath(full, src_dir))

            install_bundle(zip_path, repo_root=root, max_mb=35.0)
            self.assertFalse(os.path.exists(os.path.join(ml_dir, "vocab.json")))
            self.assertFalse(os.path.exists(os.path.join(ml_dir, "merges.txt")))
            self.assertTrue(os.path.exists(os.path.join(ml_dir, "sp_vocab.json")))
            self.assertTrue(os.path.isdir(os.path.join(ml_dir, "OneTakeParserANE.mlpackage")))
            self.assertTrue(os.path.exists(os.path.join(fixtures_dir, "golden_parity_vectors.json")))


if __name__ == "__main__":
    unittest.main()
