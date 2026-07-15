# STATUS — Cadence build progress

Updated: 2026-07-15 · Phase: **1 (MVP spine)** · Blueprint: docs/CADENCE_BLUEPRINT.md

## Phase-0 exit criteria (closed 2026-07-14, except the deferred Windows gate)

| Criterion (§32) | Status |
|---|---|
| Headless core transcribes WAV → cleaned text | ✅ 144 ms warm / 553 ms cold, 282 MB peak (M4, base.en, Metal) |
| Insertion prototype, 0 freezes / 0 corruption | ✅ automated 9/9, 0 freezes, 0 corruption (full table: `qa/matrix-results.jsonl` + git history of this file). Interactive leftovers for a user-at-keyboard pass: Spotlight, Messages, Slack, Pages, Word + not-installed apps |
| Windows insertion spike | 🔴 Deferred — no Windows env (ADR-0004); first task when one exists |
| Orchestrator + IPC schema, headless, fully tested | ✅ |
| Golden local model chosen + verified fetch | 🟡 base.en working candidate; final selection needs §30 eval harness |

## Phase-1 spine — what works today (2026-07-15)

**Live end-to-end path built:** menu-bar shell (`cadence run`) → Right-Option PTT (CGEvent
tap) → AVAudioEngine capture → FFI ring buffer → whisper.cpp (Metal, worker thread) → rule
cleanup + hallucination guard → real insertion cascade → history JSONL. All driven by the
Phase-0 orchestrator over the new C ABI (ADR-0005).

- **`core/ffi`** (`cadence-ffi`): C ABI + JSON ipc effects; compute effects interpreted
  in-core on core threads; no-lost-words drain contract (`capture_stopped` + 500 ms grace);
  panic-fenced externs. Workspace tests: **50/50** (6 FFI incl. an AC-5 regression test).
- **Swift shell** (`platform-macos`): `CCadenceFFI` (header symlinked from core),
  `CadenceCapture` (16 kHz mono i16 + RMS level), `CadenceHotkeys` (PTT/Esc tap, self-healing),
  `CadenceOverlay` (non-activating NSPanel pill: state glyph, level bars, local chip),
  `cadence` executable (menu-bar agent + effect router + WAV selftest). Build:
  `qa/build-shell.sh`.
- **E2E verification** (`qa/spine-selftest.sh`, run 3× green): WAV injected through the real
  FFI audio path → whisper → cleanup → **direct AX insertion into TextEdit**, readback
  verified, clipboard sentinel restored. **Pipeline 203–233 ms** (3.5 s utterance, model load
  ~180 ms warm), insertion 26–29 ms.
- **Safety, structural:** selftest cannot insert without a frontmost-app guard (default
  TextEdit); the Phase-0 "pasted into WhatsApp" class is closed for all automated runs.

### Fixed this session
- **AC-5 regression (found live):** ring cleared on `StartCapture` raced instant-start audio —
  first 8 000 of 56 235 samples lost, mangling leading words. Clear now happens synchronously
  in `trigger_down` on the caller thread; regression test pins the full window.

### Not yet run
- **Live mic dictation** — mic TCC is *notDetermined* for the terminal; the first
  `cadence run` must happen with the user present to grant the prompt. Everything after the
  mic is the tested path.

## What's stubbed / not started
- Streaming instant pass (§17.1 two-pass) — next spike: whisper.cpp stream vs Parakeet ONNX.
  `show_partial` is routed but never emitted. **Open risk.**
- Local small-LLM cleanup (ADR-0002 rule engine standing in), dictionary, redaction, real
  store (JSONL stand-in at `~/.cadence/history.jsonl`), undo (`arm_undo` routed, no-op),
  per-app rules, settings UI, onboarding, model registry/signing (§17.5), idle model unload
  (<150 MB budget), caret-anchored overlay, Windows everything, cloud everything.

## Current metrics vs targets (§28)

| Metric | Target | Measured |
|---|---|---|
| Local refined-pass pipeline (3.5 s utterance, M4) | ≤ 700 ms p50 | 203–233 ms (WAV-injected, incl. insertion) |
| Insertion engine call | ≤ 250 ms + fallback | 26–29 ms (direct AX, TextEdit) |
| Key-down → capture start | ≤ 50 ms perceived | **unmeasured** — needs live mic run (logged by shell) |
| Active RAM peak | < 1.2 GB | 282 MB (Phase-0 headless; shell unmeasured) |
| Idle RAM / CPU / network | <150 MB / <1% / 0 | unmeasured — needs resident-app soak |

## Open risks (watchlist)
1. **Windows spike unproven** (ADR-0004).
2. **Streaming/instant pass** — DONE for push-to-talk: `transcribe_partial` is wired into both
   interpreters (headless `Pipeline` + FFI core loop) via a shared `PartialScheduler`, with a
   load-time warmup decode; verified end-to-end over real whisper (partial "hello" + refined
   insert) by an FFI integration test — no mic needed (ADR-0006). Still open: a sliding/chunked
   window with context carry for *long* dictations — the current re-decode is O(window)/step,
   fine for short PTT (~4 s tested) but grows on multi-tens-of-seconds utterances.
3. **One-off 30 s whisper Metal stall** in a backgrounded selftest (1 of ~6 runs, never
   reproduced). Model loaded fine; the *decode* (audio→text) never returned, and the Metal
   crash fired during process-exit cleanup — confirming a decode was still in flight, not a
   load/init fault. Suspected App Nap (run launched from a script with Terminal backgrounded).
   Mitigation in place: ProcessInfo activity assertion during dictation (disables App Nap for
   the dictation window) — plausibly mitigated, NOT confirmed fixed. Containment: not
   word-losing — audio stays in the ring/history path and a hung utterance does not crash the
   hotkey listener. First suspect if any dictation hangs in "thinking". Watch during soak.
4. Direct-AX coverage across Electron/web apps still shallow (falls back to pasteRestore).
5. TTS fixtures only; WER harness (§30) not started.

## Next steps (§32 order)
1. **User at keyboard:** first live `cadence run` — grant mic prompt, dictate into TextEdit;
   capture-start latency + resource numbers land then. Then remaining interactive matrix
   targets.
2. ~~Streaming instant-pass ASR spike + wire into live loop~~ ✅ DONE (ADR-0006; shared
   `PartialScheduler`, warmup, FFI real-whisper test green). Follow-on: sliding/chunked window
   with context carry for long dictations; confirm partials render in the real overlay on the
   first live `cadence run` (shell already routes `show_partial`).
3. Model registry + signature verify (§17.5) + idle model unload (<150 MB idle budget).
4. Real store (encrypted SQLite §24) + undo + per-app rules on the live spine.
5. Windows environment → port insertion spike + this FFI (header already C-clean).
