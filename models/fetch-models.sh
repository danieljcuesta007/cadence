#!/bin/sh
# Fetch the model tiers (ADR-0003 golden candidate + §30-selected daily model).
# Integrity: sha256 pinned below (§17.5 signature/registry work replaces this in core/models).
set -eu

DIR="$(cd "$(dirname "$0")" && pwd)/artifacts"
mkdir -p "$DIR"

# name url sha256 — pins recorded at first fetch; update deliberately, never casually.
fetch() {
    NAME="$1"; URL="$2"; PIN="$3"
    MODEL="$DIR/$NAME"
    if [ -f "$MODEL" ]; then
        echo "model already present: $MODEL"
    else
        echo "downloading $NAME..."
        curl -sSfL -o "$MODEL.tmp" "$URL"
        mv "$MODEL.tmp" "$MODEL"
    fi
    ACTUAL=$(shasum -a 256 "$MODEL" | awk '{print $1}')
    if [ "$ACTUAL" != "$PIN" ]; then
        echo "sha256 mismatch for $NAME!" >&2
        echo "  expected: $PIN" >&2
        echo "  actual:   $ACTUAL" >&2
        echo "refusing to use unverified model (deleting)." >&2
        rm -f "$MODEL"
        exit 1
    fi
    echo "verified $NAME: $ACTUAL"
}

# base.en — golden rollback (§17.5); pinned 2026-07-14.
fetch ggml-base.en.bin \
    "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin" \
    "a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002"

# small.en — daily model per §30 WER harness (3.11% vs base's 5.78% on the fixture set,
# 443 ms mean decode); pinned 2026-07-19.
fetch ggml-small.en.bin \
    "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en.bin" \
    "c6138d6d58ecc8322097e0f987c32f1be8bb0a18532a3f88f734d1bbf9c41e5d"
