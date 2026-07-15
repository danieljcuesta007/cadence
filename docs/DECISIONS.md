# DECISIONS.md — running log of assumptions & judgment calls

Format: date · decision · why · reversibility. Larger decisions get an ADR in `docs/adr/`.

## 2026-07-14 (Phase 0 kickoff)

1. **Repo lives at `~/cadence`** (separate from `~/cadence-blueprint`); blueprint copied into
   `docs/` per §25. Reversible (move dir).
2. **Rust toolchain installed via rustup** (stable, minimal profile + clippy/rustfmt), user-local.
   Machine had no Rust/Homebrew/CMake. Reversible (`rustup self uninstall`).
3. **Windows spike deferred** — this dev environment is a single macOS machine; no Windows
   hardware/VM available. Phase-0 insertion de-risking proceeds on macOS; the Windows spike is the
   first task once a Windows environment exists. See ADR-0004. Risk: Windows insertion (UIA/TSF)
   is exactly where Wispr's freeze bug lives; do NOT declare the Phase-0 gate fully passed until
   the Windows spike runs.
4. **Phase-0 cleanup engine is deterministic/rule-based** (filler removal, casing, punctuation
   normalization, whitespace) with the §17.2 hallucination guard. The small local LLM is a
   Phase-1 integration; the `CleanupEngine` trait keeps the swap trivial. See ADR-0002.
5. **Local ASR spike = whisper.cpp via `whisper-rs`**, Metal-accelerated, `base.en` as the
   working "golden model candidate" (final golden model chosen per §17.5/§30 eval harness later).
   See ADR-0003.
6. **Orchestrator is a pure event→effects Mealy machine** (no threads, no I/O) interpreted by a
   thin `Pipeline` runner that owns the engine traits. Maximizes headless testability per §16.2,
   §26. See ADR-0001.
7. **CMake installed locally into `tools/cmake-local/`** (not system-wide) solely to build
   whisper.cpp; gitignored. Reversible (delete dir).
8. **Test fixture audio synthesized with macOS `say`** (16 kHz WAV) — deterministic, no
   recording/licensing concerns. Real-voice eval sets come with the §30 eval harness.
9. **IDs**: Phase-0 utterance ids are monotonic strings (`utt-N`) from the orchestrator —
   deterministic for tests, zero deps. The `core/store` layer (Phase 1) will mint UUIDv4 per
   §24 when records are persisted.
10. **whisper-rs pinned to 0.16** (not 0.14): the older crate's whisper.cpp ran the encoder on
    the CPU/BLAS path on this M4 (9.4 s for 3.5 s audio); 0.16's whisper.cpp Metal path does the
    same file in 144–553 ms. Perf measurements below in STATUS.md.
11. **Insertion spike scope**: AX-direct → paste-with-clipboard-restore → notify+copy cascade
    with `AXUIElementSetMessagingTimeout` (250 ms) as the no-freeze mechanism + all AX work off
    the calling thread. Full 20-app matrix run requires the user to grant Accessibility to the
    terminal running `qa/insertion-matrix.sh` — flagged in STATUS.md.

## 2026-07-15 (Phase 1 spine)

12. **FFI = C ABI + JSON-serialized ipc effects; compute interpreted in-core** — see ADR-0005.
    Chosen over swift-bridge (Windows-useless codegen) and sockets (latency/lifecycle cost).
13. **Capture via AVAudioEngine** (CoreAudio-backed) + `AVAudioConverter` → 16 kHz mono i16.
    Direct CoreAudio/AudioUnit is a later optimization if tap latency shows up in §28 numbers;
    the FFI contract (push_audio/capture_stopped) is capture-API-agnostic. Reversible.
14. **Default PTT = hold Right-Option (keycode 61), Esc cancels** (§12.4 suggestion). Esc is
    consumed only while a dictation is active; the CGEvent tap re-enables itself if macOS
    disables it for latency. Rebindable triggers land with F4 settings work.
15. **Selftest insertion guard is non-optional**: `cadence selftest-wav` refuses to insert
    unless the expected app (default TextEdit) is frontmost. Encodes the Phase-0 WhatsApp
    lesson structurally; live `cadence run` has no guard by design (the focused field IS the
    target).
16. **History stand-in**: inserted utterances append to `~/.cadence/history.jsonl` until the
    encrypted SQLite store (§24) lands — keeps the AC-22 "words recoverable" baseline from day
    one of live dictation.
17. **Earcons are system sounds** (Tink/Bottle/Pop/Basso) until designed assets exist (§12.6).
18. **App Nap defense**: the shell holds a `ProcessInfo` activity assertion
    (userInitiated+latencyCritical) during dictation — one unreproduced 30 s Metal decode stall
    in a backgrounded selftest is on the watchlist; this is cheap insurance and correct per §28
    regardless.
19. **Instant pass = whisper.cpp growing-window re-decode** (not a second streaming engine) —
    fast params (greedy/single_segment/no_context) + reused per-utterance state + `audio_ctx=512`
    hit ~40–90 ms/partial on M4/base.en, well under the 0.4 s cadence. Parakeet/ONNX deferred.
    See ADR-0006. Reversible (behind `AsrEngine`; `transcribe_partial` has a default impl).
20. **Instant-pass cadence lives in a shared `PartialScheduler`** (pure struct in
    `core/orchestrator`), consumed by both the headless `Pipeline` and the FFI core loop, so the
    partial timing policy can't drift between interpreters (§16.2). Warmup decode runs on the ASR
    worker at startup; `reset_stream` fires at each utterance boundary. Verified over real whisper
    by an FFI integration test (no mic). See ADR-0006.
