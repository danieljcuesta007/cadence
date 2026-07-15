# ADR-0004: Windows insertion spike deferred (no Windows environment available)

**Status:** accepted · 2026-07-14

## Context
§32 Phase 0 requires insertion-engine spikes on BOTH OSes before building on top; Windows
(UIA/TSF/SendInput) is where the market leader's freeze bug lives. The current development
environment is a single macOS machine with no Windows license/VM.

## Decision
Proceed with the macOS spike now; encode the Windows strategy contract (cascade order, 250 ms
timeout, clipboard restore, off-UI-thread) in the shared `cadence-ipc` types and the qa matrix
spec so the Windows implementation slots in. The Phase-0 gate is **not** declared fully passed
until the Windows spike runs on real hardware (VM or device).

## Consequences
- First action when a Windows environment exists: port `insertctl` semantics to a Win32/C# probe
  (UIA `TextPattern`/`ValuePattern` → TSF → SendInput → clipboard-restore), run the same matrix.
- Risk accepted consciously; recorded in STATUS.md "Open risks".
