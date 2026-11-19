"""Validates and installs a Colab-exported OneTakeParserCoreML_Bundle.zip into OneTake/MLModels/."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import tempfile
import zipfile


def _dir_size_bytes(path: str) -> int:
    total = 0
    for root, _, files in os.walk(path):
        for name in files:
            total += os.path.getsize(os.path.join(root, name))
    return total


def install_bundle(zip_path: str, repo_root: str = ".", max_mb: float = 35.0) -> None:
    ml_dir = os.path.join(repo_root, "OneTake", "MLModels")
    tests_dir = os.path.join(repo_root, "OneTakeTests")
    if not os.path.isdir(ml_dir):
        raise FileNotFoundError(f"Expected MLModels directory at {ml_dir}")

    with tempfile.TemporaryDirectory() as tmp:
        with zipfile.ZipFile(zip_path, "r") as zf:
            zf.extractall(tmp)

        sp_vocab = os.path.join(tmp, "sp_vocab.json")
        if not os.path.exists(sp_vocab):
            raise FileNotFoundError("Bundle zip missing sp_vocab.json")

        pkg_names = [
            name for name in ("OneTakeParserANE.mlpackage", "OneTakeParserEncoder.mlpackage", "OneTakeParserDecoder.mlpackage")
            if os.path.isdir(os.path.join(tmp, name))
        ]
        if not pkg_names:
            raise FileNotFoundError("Bundle zip missing Core ML .mlpackage directory")

        total_bytes = os.path.getsize(sp_vocab) + sum(_dir_size_bytes(os.path.join(tmp, n)) for n in pkg_names)
        total_mb = total_bytes / (1024.0 * 1024.0)
        if total_mb > max_mb:
            raise ValueError(f"Bundle footprint {total_mb:.2f} MB exceeds {max_mb} MB cap!")

        # Remove legacy Qwen assets
        for legacy in ("OneTakeParserANE.mlpackage", "OneTakeParserEncoder.mlpackage", "OneTakeParserDecoder.mlpackage", "vocab.json", "merges.txt"):
            target = os.path.join(ml_dir, legacy)
            if os.path.isdir(target):
                shutil.rmtree(target)
            elif os.path.isfile(target):
                os.remove(target)

        shutil.copy2(sp_vocab, os.path.join(ml_dir, "sp_vocab.json"))
        for pkg in pkg_names:
            shutil.copytree(os.path.join(tmp, pkg), os.path.join(ml_dir, pkg))

        golden_src = os.path.join(tmp, "golden_parity_vectors.json")
        if os.path.exists(golden_src):
            shutil.copy2(golden_src, os.path.join(tests_dir, "TestFixtures", "golden_parity_vectors.json"))

        metrics_src = os.path.join(tmp, "eval_metrics.json")
        if os.path.exists(metrics_src):
            with open(metrics_src, "r", encoding="utf-8") as f:
                print("Colab Eval Metrics:", json.dumps(json.load(f), indent=2))

        print(f"Installed {pkg_names} + sp_vocab.json into {ml_dir} (total {total_mb:.2f} MB).")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("bundle_zip", help="Path to OneTakeParserCoreML_Bundle.zip from Colab Pro")
    parser.add_argument("--repo-root", default=".")
    parser.add_argument("--max-mb", type=float, default=35.0)
    args = parser.parse_args()
    install_bundle(args.bundle_zip, repo_root=args.repo_root, max_mb=args.max_mb)
