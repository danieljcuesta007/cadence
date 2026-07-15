#!/bin/sh
# Fetch the Phase-0 "golden model candidate" (ADR-0003): whisper.cpp ggml-base.en.
# Integrity: sha256 pinned below (§17.5 signature/registry work replaces this in core/models).
set -eu

DIR="$(cd "$(dirname "$0")" && pwd)/artifacts"
mkdir -p "$DIR"
MODEL="$DIR/ggml-base.en.bin"
URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin"
# sha256 of ggml-base.en.bin as first fetched 2026-07-14; update deliberately, never casually.
SHA256_PIN="a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002"

if [ -f "$MODEL" ]; then
    echo "model already present: $MODEL"
else
    echo "downloading ggml-base.en.bin (~142 MB)..."
    curl -sSfL -o "$MODEL.tmp" "$URL"
    mv "$MODEL.tmp" "$MODEL"
fi

ACTUAL=$(shasum -a 256 "$MODEL" | awk '{print $1}')
if [ "$ACTUAL" != "$SHA256_PIN" ]; then
    echo "sha256 mismatch!" >&2
    echo "  expected: $SHA256_PIN" >&2
    echo "  actual:   $ACTUAL" >&2
    echo "refusing to use unverified model (deleting)." >&2
    rm -f "$MODEL"
    exit 1
fi
echo "verified: $ACTUAL"
