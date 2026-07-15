# Cadence

Local-first, cloud-optional, system-wide AI voice dictation for macOS and Windows.

**Single source of truth:** [`docs/CADENCE_BLUEPRINT.md`](docs/CADENCE_BLUEPRINT.md) (PRD + TDD + UX spec + roadmap).
Current progress: [`docs/STATUS.md`](docs/STATUS.md) · Decisions: [`docs/DECISIONS.md`](docs/DECISIONS.md) · ADRs: [`docs/adr/`](docs/adr/)

## Repo layout (blueprint §25)

```
core/               shared Rust core (orchestrator, asr, cleanup, dictionary, redaction,
                    store, sync, privacy, ipc, models) — platform-agnostic, headless-testable
platform-macos/     Swift/AppKit shell (capture, hotkeys, overlay, insertion, settings)
platform-windows/   C++/C# shell (WASAPI, hotkeys, overlay, UIA/TSF insertion)
cloud/              optional backend (gateway, asr/llm/sync/account services)
models/             model build/quantize/eval pipelines + eval sets
shared-protocol/    API + IPC schema (source of truth)
qa/                 test harnesses (insertion matrix, a11y, latency, WER eval)
docs/               blueprint, ADRs, status, decisions
tools/              release, signing, local toolchain helpers
```

## Building (Phase 0)

Rust core:

```sh
cargo test --workspace           # headless core: orchestrator, cleanup, ring buffer
cargo run -p cadence-headless -- --wav qa/fixtures/hello.wav   # WAV → cleaned text
```

macOS insertion spike:

```sh
cd platform-macos && swift build
.build/debug/insertctl check     # permission / capability report
.build/debug/insertctl insert "hello from cadence"
```

## Non-negotiable gates

1. Never lose a user's words. 2. Never freeze or corrupt the target app (0 freezes / 0 clipboard
corruption is a release blocker). 3. Fully offline baseline. 4. Legible privacy (per-utterance
badge, zero retention, no screenshots). 5. Idle < 150 MB RAM / < 1% CPU / zero network.
6. Flagship onboarding (< 60 s to first dictation).
