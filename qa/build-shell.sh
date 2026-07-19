#!/bin/bash
# Build the full macOS shell: Rust core (staticlib, whisper+Metal) then the Swift package.
# Toolchain quirks: rustup is user-local; whisper.cpp needs the vendored CMake.
set -euo pipefail
cd "$(dirname "$0")/.."
source ~/.cargo/env
export CMAKE="${CMAKE:-$PWD/tools/cmake-local/cmake-3.31.7-macos-universal/CMake.app/Contents/bin/cmake}"
cargo build --release -p cadence-ffi --features whisper
# SwiftPM does not track the external staticlib: a fresh libcadence_ffi.a with unchanged
# Swift sources would NOT relink, silently shipping the old core. Force the link step.
BIN=platform-macos/.build/release/cadence
if [[ -f "$BIN" && target/release/libcadence_ffi.a -nt "$BIN" ]]; then
    rm -f "$BIN"
fi
( cd platform-macos && swift build -c release )
echo "shell binary: platform-macos/.build/release/cadence"
