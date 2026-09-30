#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

forbidden_suffixes = {".pyc", ".o", ".a"}
for p in ROOT.rglob("*"):
    if not p.is_file():
        continue
    assert p.suffix not in forbidden_suffixes, f"generated artifact in source tree: {p}"
    assert p.name != "__pycache__", f"bytecode cache in source tree: {p}"

assert not any(p.is_dir() and p.name == "__pycache__" for p in ROOT.rglob("__pycache__")), "__pycache__ directory in source tree"

logo = (ROOT / "assets/logo.png").read_bytes()
assert logo.startswith(b"\x89PNG\r\n\x1a\n"), "assets/logo.png is not a valid PNG file"

# Documentation must describe the RVM/ORT tree, not the removed SDK workflow.
doc_text = "\n".join(
    (ROOT / name).read_text()
    for name in ["README.md", "SECURITY.md", "HARDENING_NOTES.md", "CONTRIBUTING.md", "LICENSE"]
)
for stale in ["VideoFX", "TensorRT-8.5.1.7", "sdk.tar.gz", "MATTECAST_ENABLE_CC_SPOOF"]:
    assert stale not in doc_text, f"stale legacy documentation reference: {stale}"

print("source tree hygiene tests passed")
