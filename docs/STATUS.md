# STATUS — Cadence build progress

Updated: 2026-07-18 · Phase: **1 (MVP spine)** · Blueprint: docs/CADENCE_BLUEPRINT.md

## Resource soak + stall hunt (2026-07-18)

**Idle soak found a real crash.** The resident app had idled 8 h 42 m (natural soak: avg CPU
≈0.008 %, 0 sockets, phys footprint 176–218 MB — CMPRS shows nearly all of it is the
OS-compressed whisper model; RSS settles ~25 MB). Then, ~20 min after a successful live
dictation, the app **aborted on an audio route change**: `AVAudioEngineConfigurationChange` →
observer (on the posting thread, un-debounced) → `teardownTap`+`prewarm` → `installTapOnNode`
raised an ObjC `NSException` mid-reconfiguration → uncatchable in Swift → SIGABRT
(`Cadence-2026-07-18-200950.ips`). Fix (same day):
- `CObjCCatch` target: `CadenceCatchNSException` fences the install; a raise now degrades to
  `CaptureError.tapInstall` (prewarm swallows it; next `start()` rebuilds cold — that
  recovery path already existed). Fence unit-proven (raise caught, clean path nil).
- Route-change rebuild now debounced 150 ms onto the main queue (changes burst on arbitrary
  threads; re-tapping while the engine reconfigures is what raised).
- `ensureTap` also guards `channelCount > 0` (transitional formats can be 48 kHz / 0 ch).
- Not yet re-proven against a real route change — plug/unplug AirPods while idle to confirm.

**Metal stall hunt: 10/10 clean.** ~380 headless whisper+Metal decodes (stream_spike partials
×3 audio_ctx + refined, 120 s watchdog, launched non-foreground): zero stalls, refined decode
~113 ms. The one-off 30 s stall did not reproduce headlessly; App Nap on the .app process
remains prime suspect and the activity-assertion mitigation stands.

**Budget verdict (§28 idle):** CPU <1 % PASS (≈0.008 %), network 0 PASS, RAM <150 MB **MISS
by ~26–68 MB**, entirely the resident model (compressed while idle). Confirms the idle
model-unload lever (ADR-0006) is what closes it. Sampler: `qa/soak.sh` →
`qa/soak-results.jsonl` (30 s interval; footprint/CMPRS/RSS/cputime/threads/sockets).

## Phase-0 exit criteria (closed 2026-07-14, except the deferred Windows gate)

| Criterion (§32) | Status |
|---|---|
| Headless core transcribes WAV → cleaned text | ✅ 144 ms warm / 553 ms cold, 282 MB peak (M4, base.en, Metal) |
| Insertion prototype, 0 freezes / 0 corruption | ✅ automated 9/9, 0 freezes, 0 corruption (full table: `qa/matrix-results.jsonl` + git history of this file). Interactive pass 2026-07-16: Spotlight, Pages, Word, VS Code, Messages + Slack (both draft-to-self, never sent, drafts cleared) — 6/6 PASS. Still uncovered: not-installed apps (iTerm2, Cursor, Discord, JetBrains) |
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
- **Overlay level bars invisible (found on first live run):** core emitted `update_waveform`
  correctly (36/utterance, verified via `CADENCE_DEBUG=1` selftest) but the pill's fixed
  260 pt width over-constrained the stack once the bars appeared — AppKit clipped the level
  label. Pill now sizes to content; level label holds a constant 10-glyph width while
  listening so per-chunk updates never relayout.
- **`show_partial` was a stub in the shell router** (previous STATUS claim "shell already
  routes show_partial" was wrong — it parsed but dropped it). Now rendered: instant-pass text
  shows in the pill, head-truncated, and stays up through "thinking" while the refined pass runs.
- **Emoji purge (design rule: no emojis, professional/clean):** overlay glyphs are now
  typographic marks, chip is plain "local"/"cloud", menu-bar icon uses template SF Symbols
  (`mic`/`mic.fill`/…) instead of 🎙/🔴.

### First live mic run (2026-07-15) — PASSED
- Mic TCC granted; 4 dictations, ~90 % word accuracy (user-reported), no freezes.
- Capture start 79–153 ms (85–94 ms warm) — **misses the ≤50 ms perceived target**; needs a
  look (engine pre-warm / keep AVAudioEngine hot between utterances?).
- Insertion live: direct 115 ms once, paste_restore 254–270 ms otherwise (targets non-TextEdit
  apps → cascade fell back as designed); clipboard restored every time.
- Overlay bars/partials were NOT visible on this run — root-caused and fixed above; re-test pending.

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
| Key-down → capture start | ≤ 50 ms perceived | **47 / 36 ms live (2026-07-16, warm path) — target MET** (was 85–94 ms) |
| Active RAM peak | < 1.2 GB | 282 MB (Phase-0 headless; shell unmeasured) |
| Idle RAM / CPU / network | <150 MB / <1% / 0 | 176–218 MB footprint (≈all compressed model; RSS ~25 MB) / ≈0.008 % / 0 sockets — RAM misses until idle model unload (2026-07-18 soak) |

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
1. ~~First live `cadence run`~~ ✅ DONE 2026-07-15 (mic granted, ~90 % accuracy). Overlay
   bars+partials fix CONFIRMED live 2026-07-16. ~~Interactive matrix~~ ✅ DONE 2026-07-16
   (agent-driven, idle-gated, focus-guarded): Spotlight, Pages, Word, VS Code, Messages
   + Slack (both draft-to-self, never sent, drafts cleared) — 6/6 PASS, pasteRestore
   297–343 ms, 0 freezes, 0 clipboard corruption, undo verified in Pages/Word/VS Code.
   Slack: deep link to own-user DM + window-title allowlist before pasting. Findings:
   - **Blind-paste gap (release-gate relevant, §30/AC-20):** in Pages with page-layout focus
     (Book template), pasteRestore returned `inserted: true` but the text landed nowhere.
     The engine cannot distinguish "pasted into a text field" from "paste swallowed". Consider
     post-insert verification (AX readback where possible) before reporting success / arming undo.
   - AX-opaque surfaces are common: Spotlight panel, Pages body/template-chooser/save-sheet,
     VS Code editor (role None) — direct AX impossible there; cascade correctly fell back.
   - Spotlight: systemwide AX focus stays on the previous app while the panel is key, so
     insertion works only because synthetic ⌘V routes to the key window.
   - Electron cold start: first paste into a just-launched VS Code fired before the editor had
     keyboard focus (buffer preserved it via hot exit, but timing matters for real dictation).
   - This machine has ⌘Space disabled (symbolic hotkey 64 off) — Spotlight was opened via a
     CGEvent click on the menu-bar icon.
   Resource soak numbers still unmeasured.
1b. **Cadence.app shipped (2026-07-16, e843c18):** real menu-bar app at `~/Applications/Cadence.app`
   (built by `qa/package-app.sh --install`): LSUIElement agent, bundled model (resolution:
   env → bundle → dev path), ad-hoc signed, Accessibility onboarding (prompt + poll, no
   fatalError), mic usage string. New TCC identity ⇒ user must re-grant mic + Accessibility
   to "Cadence" on first launch. Warm capture path landed same commit: tap+converter built
   once (rebuilt on route change), prepare() re-armed after stop, prewarm() at launch —
   expected to cut the 85–94 ms capture start toward ≤50 ms; **needs live re-measure**.
   Engine still fully stops between utterances (mic indicator = actual listening); if still
   over target, next lever is engine.pause() (verify orange dot goes off first).
1c. **Dashboard + observability (2026-07-16, 7424305 + 9ee75dd):** menu → "History &
   Metrics…" — KPI tiles (dictations, words, avg capture start, avg insertion) + history
   table; history.jsonl enriched per utterance (capture_start_ms, capture_window_ms,
   insertion_ms, strategy, frontmost app). Diagnostics tee to `~/.cadence/logs/cadence.log`
   (the .app's stderr is unobservable). **Ad-hoc TCC trap, hit live:** each rebuild's new
   cdhash silently stales the Accessibility grant while the Settings toggle still shows ON —
   toggling does NOT rebind; only `tccutil reset` + fresh grant does. SOLVED (35c1d31):
   `qa/setup-signing.sh` creates the self-signed "Cadence Dev Signing" identity (dedicated
   pre-authorized keychain, user-domain codeSign trust); package-app.sh signs with it, DR =
   identifier + certificate leaf. **Verified live: grants survived a rebuild+reinstall with
   zero re-prompts (2026-07-16 09:51).**
2. ~~Streaming instant-pass ASR spike + wire into live loop~~ ✅ DONE (ADR-0006; shared
   `PartialScheduler`, warmup, FFI real-whisper test green). Shell now renders `show_partial`
   in the pill (was a stub until 2026-07-15). Follow-on: sliding/chunked window with context
   carry for long dictations.
3. Model registry + integrity ✅ DONE (`core/models`: dependency-free SHA-256 + `ModelRegistry`
   verify/golden-rollback §17.5/§29; FFI `cadence_model_verify` gate; ADR-0007). Remaining:
   **idle model unload (<150 MB)** — designed, deferred (tension w/ ~7 s cold load, ADR-0006);
   asymmetric signature verify (needs signing key); full registry-resolve over FFI + a manifest
   in the shell.
4. Real store (encrypted SQLite §24) + undo + per-app rules on the live spine (registry's
   `ModelStore` trait already plugs in here).
5. Windows environment → port insertion spike + this FFI (header already C-clean).
