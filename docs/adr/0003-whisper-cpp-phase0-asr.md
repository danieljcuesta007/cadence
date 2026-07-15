# ADR-0003: whisper.cpp (`whisper-rs`) as the Phase-0 local ASR spike

**Status:** accepted · 2026-07-14

## Context
§17.1 asks for a streaming Parakeet/Whisper-class local ASR with Core ML/Metal acceleration,
driven from the Rust core via a portable runtime. Phase 0 needs a working WAV→text path plus
latency/resource numbers, not the final golden model (§17.5 says that's chosen via the §30 eval
harness).

## Decision
Use whisper.cpp through the `whisper-rs` crate (GGML-class, Metal on Apple Silicon), model
`ggml-base.en` as the working candidate, behind the `AsrEngine` trait (feature-gated `whisper`
feature so the core builds and tests with a mock when the model/toolchain is absent). Models
live in `models/artifacts/` (gitignored), fetched by `models/fetch-models.sh` with SHA
verification (registry/signing per §17.5 comes with `core/models`).

## Consequences
- Streaming/instant-pass (partial hypotheses) is NOT covered by whisper.cpp's plain API; the
  two-pass instant/refined design (§17.1) will need either whisper.cpp's streaming mode or a
  Parakeet-class streaming model in Phase 1 — tracked in STATUS.md as an open risk.
- English-only model for the spike; multilingual per §7 F13 later.
- CMake required to build whisper.cpp; installed locally under `tools/cmake-local/`.
