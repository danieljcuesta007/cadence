# ADR-0006: Instant pass via whisper.cpp growing-window re-decode

**Status:** accepted (spike) · 2026-07-15

## Context
§12.3 strategy B needs a two-pass ASR: a fast **instant pass** that surfaces a live partial
while the user is still speaking, plus the existing authoritative **refined pass** over the
finalized window. `show_partial` is already routed through the FFI to the shell overlay; the
open question (NEXT §32.2) was whether the instant pass can be met by the whisper.cpp engine
already in the tree, or whether it forces a second, streaming-first engine (Parakeet-class
ONNX + a model registry) before we have one.

Two candidate engines:
- **whisper.cpp (in tree, `base.en`, Metal).** Zero new runtime; reuses the proven build,
  FFI, and Metal path. Not designed for streaming — the question was latency on short windows.
- **Parakeet-class ONNX.** Purpose-built for streaming partials, but pulls in an ONNX runtime,
  a second engine to maintain, and the §17.5 model registry — all currently unbuilt.

## Spike
`core/asr/examples/stream_spike.rs` simulates the live path: feed a 16 kHz mono WAV in growing
0.4 s windows and run `transcribe_partial` on each accumulated window (as if still speaking),
then the refined pass. Instant-pass config: `Greedy{best_of:1}`, `single_segment`,
`no_context`, `suppress_blank`, a **reused decode state** across the stream (pay
`whisper_init_state` once per utterance, not per partial), and a swept `audio_ctx` cap (the
encoder-length knob whisper.cpp's own `stream` example exposes as `--audio-ctx`).

Measured on M4, `base.en`, Metal, two fixtures (~3.5–3.9 s):

| audio_ctx        | steady-state / partial | worst step | notes                                   |
|------------------|------------------------|------------|-----------------------------------------|
| default (1500)   | ~90–140 ms             | 178 ms     | full 30 s encoder every step            |
| 512              | ~40–90 ms              | 90 ms      | stable; best trailing-word coverage     |
| 256              | ~35–70 ms              | 74 ms\*    | fastest steady-state; one 869 ms outlier |

\* one unreproduced 869 ms spike at audio_ctx=256 on the fillers fixture; see risks.

Refined pass unchanged: 134–180 ms over the full window. Partials converge on the refined text
and rewrite earlier words as context grows (`case` → `cadence`), confirming the UI must treat
partials as replaceable (which `show_partial` already implies).

## Decision
1. **Ship the instant pass on whisper.cpp** — growing-window re-decode with the fast params
   above and a reused per-utterance state. It clears the budget with headroom: steady-state
   partial latency (~40–90 ms) sits well under the 0.4 s partial cadence. **Do not** add a
   Parakeet/ONNX engine now; revisit only if long-utterance windows or accuracy force it.
2. **Default `audio_ctx = 512.** 256 was marginally faster but showed a tail spike and slightly
   worse trailing words; 512 gave stable ≤90 ms. Sized to a rolling-window cap (~50 frames/s),
   so it must grow with, or the window must be capped to, the coverage it implies.
3. **API:** `AsrEngine::transcribe_partial` (default impl delegates to `transcribe` and relabels
   as `instant`, so non-whisper engines stay correct); `WhisperAsr` adds the fast path,
   `set_partial_audio_ctx`, and `reset_stream` for utterance boundaries.

## Status update — wired (2026-07-15)
The API is now integrated, not just spiked. A shared `PartialScheduler` (`core/orchestrator`,
pure/unit-tested) owns the cadence policy (fire every ~0.4 s once ≥0.3 s exists; coalesce while a
partial is in flight) so the headless `Pipeline` and the FFI core loop can't diverge (§16.2).
The FFI ASR worker runs `Partial` vs `Final` jobs, calls `reset_stream` at each utterance
boundary, and does a load-time warmup decode. Verified end-to-end over real whisper (no mic) by
`instant_pass_over_real_whisper_emits_partial_then_final`: `hello.wav` pushed through the C ABI
yields a live `show_partial` ("hello") and the refined insert. `RingBuffer::snapshot` gives the
instant pass a non-destructive read of the growing window.

## Consequences / open risks
- **Warmup:** the first partial after model load spikes (Metal pipeline warmup). ✅ Addressed —
  the ASR worker issues a throwaway warmup decode (refined + partial paths) at startup.
- **Long dictations:** the growing-window re-decode is O(window)/step — fine for the ~4 s PTT
  windows tested, but a sliding/chunked window with context carry is still needed before
  multi-tens-of-seconds utterances. Open follow-on.
- **Cold model load ~7 s vs ~160 ms warm** (OS file cache). Argues for loading at session start
  and keeping the model resident — in tension with the <150 MB idle-unload budget (NEXT §32.3);
  resolve there (e.g. unload only after a longer idle).
- **Tail latency:** the single 869 ms outlier at audio_ctx=256 is unreproduced and distinct from
  the 30 s Metal hang on the STATUS watchlist, but tail latency should be tracked in soak.
- **Growing-window re-decode is O(window)/step.** Fixtures are ~4 s push-to-talk; long dictations
  need a sliding/chunked window with context carry. Not exercised here — the next design step for
  the production streaming impl.

## Reversibility
High. The engine sits behind `AsrEngine`; `transcribe_partial` has a working default, so
swapping in a streaming-first engine later is local to `core/asr`. Spike harness is an example
(not shipped). No FFI or schema change.
