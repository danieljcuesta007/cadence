# STATUS — Cadence build progress

Updated: 2026-07-14 · Phase: **0 (foundations & spikes)** · Blueprint: docs/CADENCE_BLUEPRINT.md

## Phase-0 exit criteria

| Criterion (§32) | Status |
|---|---|
| Headless core transcribes WAV → cleaned text | ✅ **Met.** `cargo run -p cadence-headless --features whisper -- --wav qa/fixtures/hello.wav` runs mic-window → whisper.cpp (Metal) → rule cleanup + hallucination guard → insertion sink, through the real orchestrator. |
| Insertion prototype passes 20-app subset, 0 freezes / 0 corruption | 🟡 **Engine built + invariants proven headlessly; real-app matrix awaits a one-time user permission.** `insertctl selftest` (5/5): deadline abandonment ≤1 s on a 5 s stall, byte-exact multi-type clipboard restore, third-party-write never clobbered. Degraded path verified live (no AX grant → words parked on clipboard, honest report, 19 ms). **Blocked on:** granting Accessibility to the harness terminal (System Settings → Privacy & Security → Accessibility), then `qa/insertion-matrix.sh`. |
| Windows insertion spike | 🔴 **Deferred — no Windows environment on this machine** (ADR-0004). First task when one exists. |
| Orchestrator + IPC schema, headless, fully tested | ✅ 44 Rust tests green (all §12.2 transitions, cancel at each stage, cloud→local fallbacks, stale-callback rejection, interference abort, per-app disable, privacy truth, ring-buffer no-lost-words). |
| Golden local model chosen + verified fetch | 🟡 Working candidate: whisper.cpp `ggml-base.en` (sha256-pinned fetch script). Final golden model selection needs the §30 eval harness (Phase 1). Signing/registry (§17.5) not built yet. |

## What works today

- **Rust core** (`cargo test --workspace`: 44/44): `cadence-ipc` typed event/effect schema;
  `cadence-orchestrator` pure state machine + ring buffer + headless pipeline;
  `cadence-cleanup` rule engine + §17.2 hallucination guard; `cadence-asr` trait + mock +
  whisper.cpp (Metal) behind a feature flag.
- **WAV → cleaned text** (Apple M4, base.en): **asr 144 ms warm / 553 ms first-run** on a 3.5 s
  utterance; cleanup <1 ms; **peak RSS 282 MB** with model loaded. §28 budgets: local p50 ≤
  700 ms ✅ (warm), active RAM < 1.2 GB ✅. (Idle <150 MB budget is about model unload — Phase 1.)
- **macOS insertion engine spike** (`platform-macos`): capability detection (AX trust, secure
  event input, focused role/settability) → cascade **direct AX → paste-with-restore →
  clipboard+notify**, every strategy off-thread with a 250 ms deadline +
  `AXUIElementSetMessagingTimeout`; secure fields refused outright; clipboard snapshot/restore
  refuses to clobber third-party writes. `insertctl` CLI: `check` / `insert` / `selftest`.
- **QA harness**: `qa/insertion-matrix.sh` + 20-app spec in `qa/INSERTION_MATRIX.md`.

## What's stubbed / not started

- Streaming instant-pass ASR (two-pass §17.1) — whisper.cpp plain API is batch; Phase 1 needs
  its streaming mode or a Parakeet-class model. **Open risk.**
- Local small-LLM cleanup (rule-based stand-in per ADR-0002), dictionary, redaction, store,
  sync, privacy dashboard, overlay/HUD, hotkeys, capture (CoreAudio), Windows everything,
  cloud everything.
- FFI surface for shells (pipeline runner exists; `swift-bridge`/C-ABI export not yet).

## Current metrics vs targets (§28)

| Metric | Target | Measured |
|---|---|---|
| Local refined-pass latency (3.5 s utterance, M4) | ≤ 700 ms p50 | 144 ms warm; 553 ms first-run |
| Active RAM peak (model loaded) | < 1.2 GB | 282 MB |
| Insertion engine call bound | ≤ 250 ms + fallback | deadline enforced; degraded path 19 ms |
| Idle RAM / CPU / network | <150 MB / <1% / 0 | n/a — no resident app yet |

## Open risks (watchlist)

1. **Windows spike unproven** — the market leader's freeze bug lives there (ADR-0004).
2. **Streaming/instant pass** unsolved for the local engine (affects §12.3 strategy B).
3. Direct-AX insertion coverage across Electron/web apps unknown until the matrix runs.
4. TTS fixtures only; real-voice eval sets + WER harness (§30) not started.

## Next steps (in order)

1. **User action:** grant Accessibility to the terminal → run `qa/insertion-matrix.sh` → paste
   results here; fix what fails until the 20-app subset is green.
2. CoreAudio capture + hotkey listener + minimal overlay (menu-bar shell) driving the same
   orchestrator over FFI — first live end-to-end dictation on macOS.
3. Streaming instant-pass spike (whisper.cpp stream mode vs Parakeet-class ONNX).
4. Model registry + signature verification (§17.5); idle unload for the <150 MB budget.
5. Windows environment → port the insertion spike (ADR-0004).
