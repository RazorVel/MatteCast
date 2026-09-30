#!/bin/bash
set -euo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODEL_DIR="$ROOT/models"
MODEL="$MODEL_DIR/rvm_mobilenetv3_fp32.onnx"
URL="https://github.com/PeterL1n/RobustVideoMatting/releases/download/v1.0.0/rvm_mobilenetv3_fp32.onnx"
SHA256="88d4531297118f595bf2fd60f6f566aec2e559393802d1f436c380f0cbbd2828"
SIZE=14975696

command -v curl >/dev/null 2>&1 || { echo "Error: curl is required" >&2; exit 1; }
command -v sha256sum >/dev/null 2>&1 || { echo "Error: sha256sum is required" >&2; exit 1; }

if [ -L "$MODEL_DIR" ] || { [ -e "$MODEL_DIR" ] && [ ! -d "$MODEL_DIR" ]; }; then
    echo "Error: unsafe models path: $MODEL_DIR" >&2
    exit 1
fi
install -d -m 755 "$MODEL_DIR"

if [ -f "$MODEL" ] && [ ! -L "$MODEL" ]; then
    if [ "$(stat -c %s -- "$MODEL")" = "$SIZE" ] && \
       printf '%s  %s\n' "$SHA256" "$MODEL" | sha256sum -c - >/dev/null 2>&1; then
        echo "RVM model already present and verified."
        exit 0
    fi
    echo "Error: existing model failed verification; remove it manually before retrying: $MODEL" >&2
    exit 1
fi
[ ! -e "$MODEL" ] || { echo "Error: unsafe/non-regular model path: $MODEL" >&2; exit 1; }

tmp="$(mktemp "$MODEL_DIR/.rvm-download.XXXXXX")"
trap 'rm -f "$tmp"' EXIT INT TERM

curl --fail --location --proto '=https' --proto-redir '=https' --tlsv1.2 \
    --retry 3 --retry-all-errors --connect-timeout 15 --max-time 300 \
    -o "$tmp" "$URL"

[ "$(stat -c %s -- "$tmp")" = "$SIZE" ] || { echo "Error: model size mismatch" >&2; exit 1; }
printf '%s  %s\n' "$SHA256" "$tmp" | sha256sum -c - >/dev/null
chmod 644 "$tmp"
mv -fT "$tmp" "$MODEL"
trap - EXIT INT TERM
printf 'Verified RVM model saved to %s\n' "$MODEL"
