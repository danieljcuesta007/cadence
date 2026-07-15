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
