#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
fetch = (ROOT / "scripts/fetch-rvm-model.sh").read_text()
install = (ROOT / "install.sh").read_text()
container = (ROOT / "Containerfile").read_text()
requirements = (ROOT / "app/gui-requirements.txt").read_text()

MODEL_SHA = "88d4531297118f595bf2fd60f6f566aec2e559393802d1f436c380f0cbbd2828"
ORT_SHA = "2083e361072a79ce16a90dcd5f5cb3ab92574a82a3ce0ac01e5cfa3158176f53"
PYSIDE_ESSENTIALS_SHA = "1f41f357ce2384576581e76c9c3df1c4fa5b38e347f0bcd0cae7c5bce42a917c"
SHIBOKEN_SHA = "b1aeff0d79d84ddbdc9970144c1bbc3a52fcb45618d1b33d17d57f99f1246d45"

assert "https://github.com/PeterL1n/RobustVideoMatting/releases/download/v1.0.0/rvm_mobilenetv3_fp32.onnx" in fetch
assert MODEL_SHA in fetch and MODEL_SHA in install
assert "--proto '=https'" in fetch and "--proto-redir '=https'" in fetch
assert "sha256sum -c" in fetch and "sha256sum -c" in install
assert "mv -fT" in fetch
assert "14975696" in fetch and "14975696" in install

assert "https://github.com/microsoft/onnxruntime/releases/download/" in container
assert ORT_SHA in container
assert "sha256sum -c" in container

assert "PySide6-Essentials==6.6.3.1" in requirements
assert "shiboken6==6.6.3.1" in requirements
assert PYSIDE_ESSENTIALS_SHA in requirements
assert SHIBOKEN_SHA in requirements
assert "PySide6-Addons" not in requirements
assert "--require-hashes" in container
assert "--only-binary=:all:" in container
assert "--no-deps" in container
assert "--index-url https://pypi.org/simple" in container

print("model/dependency supply-chain tests passed")
