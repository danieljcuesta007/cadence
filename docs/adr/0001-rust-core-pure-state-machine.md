# ADR-0001: Rust core with a pure event→effects orchestrator

**Status:** accepted · 2026-07-14

## Context
Blueprint §16.2/§26 mandate one shared orchestrator state machine driving both native shells,
headlessly testable. The naive design (orchestrator owns threads, engines, and I/O) is hard to
test exhaustively and couples platform concerns into core.

## Decision
- `core/ipc` (crate `cadence-ipc`) is the typed schema: states, events, effects, transcripts,
  insertion strategies/outcomes, privacy accounting. Serde-serializable = the FFI/IPC source of
  truth (§23 "Local IPC").
- `core/orchestrator` (crate `cadence-orchestrator`) exposes `Orchestrator::handle(Event) ->
  Vec<Effect>`: a pure, synchronous Mealy machine. No threads, no clocks, no I/O. Every §12.2
  transition, cancel path, fallback, and concurrency rule is a unit test.
- A `Pipeline` runner (same crate, `pipeline` module) interprets effects against engine traits
  (`AsrEngine`, `CleanupEngine`, `InsertionSink`) for headless end-to-end runs and, later, for
  the shells via FFI.

## Consequences
- mac/Win parity is structural: shells only translate OS events → `Event` and render effects.
- Timeouts/threading live in the interpreters (shells/pipeline), not the machine; the machine
  models them as events (`CloudTimedOut`, `InsertionFailed`), keeping them deterministic to test.
