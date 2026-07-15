# ADR-0005: C-ABI FFI with in-core effect interpretation

**Status:** accepted · 2026-07-15

## Context
Phase 1 needs the native shells to drive the Rust core (§16.2, §23). Options considered:
`swift-bridge` (typed Swift bindings, but adds a codegen toolchain and a Windows-useless
layer), a full JSON-RPC over sockets (process isolation, but latency + lifecycle cost), or a
minimal C ABI (works identically for Swift now and C++/C# on Windows later).

A second question: which side interprets compute effects (`run_asr`, `run_cleanup`)? If the
shell does (like the headless `Pipeline`), every shell reimplements threading, drain timing,
and fallback semantics — the exact class of divergence §16.2 exists to prevent.

## Decision
- `core/ffi` (crate `cadence-ffi`, staticlib/cdylib/rlib) exposes a small C ABI
  (`include/cadence_ffi.h`): engine lifecycle, `trigger_down/up`, `cancel`, `push_audio`,
  `capture_stopped`, `insertion_result/failed`.
- Effects cross the boundary as **JSON in the `cadence-ipc` schema** (one effect per callback,
  in order, on a core thread). The serde schema stays the single source of truth; no parallel
  C struct mirror to drift.
- **Compute effects are interpreted in-core** on core-owned threads (§16.3): orchestrator
  loop thread + a dedicated ASR worker so cancel stays responsive mid-decode; cleanup runs
  inline (sub-ms). Shells only see presentation + insertion effects — they stay thin
  interpreters (ADR-0001 unchanged: the machine itself is still pure and fully unit-tested).
- **No-lost-words drain contract:** on `TriggerUp` the core defers the ASR window drain until
  the shell confirms `capture_stopped` (its final in-flight audio buffer has been pushed),
  with a 500 ms grace fallback. Stale-tail clearing happens synchronously in `trigger_down`
  on the caller thread — clearing on `StartCapture` raced instant-start audio and ate the
  first ~0.5 s (caught live, pinned by regression test).

## Consequences
- Windows shell consumes the identical header + semantics; zero Swift-specific machinery.
- JSON serialization cost on the hot path is negligible (presentation-rate messages; measured
  pipeline 203–233 ms end-to-end incl. whisper decode + insertion).
- Panic safety: every extern fn is `catch_unwind`-wrapped; errors surface via
  `cadence_last_error` (thread-local).
- The callback fires on a core thread; shells must trampoline to their UI thread (the Swift
  `EffectRouter` does).
