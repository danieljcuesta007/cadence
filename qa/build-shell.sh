#!/bin/bash
# Build the full macOS shell: Rust core (staticlib, whisper+Metal) then the Swift package.
# Toolchain quirks: rustup is user-local; whisper.cpp needs the vendored CMake.
set -euo pipefail
cd "$(dirname "$0")/.."
source ~/.cargo/env
export CMAKE="${CMAKE:-$PWD/tools/cmake-local/cmake-3.31.7-macos-universal/CMake.app/Contents/bin/cmake}"
cargo build --release -p cadence-ffi --features whisper
( cd platform-macos && swift build -c release )
echo "shell binary: platform-macos/.build/release/cadence"
