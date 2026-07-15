# ADR-0002: Phase-0 cleanup is deterministic rules; local LLM deferred to Phase 1

**Status:** accepted · 2026-07-14

## Context
§17.2 specifies a small local instruction-tuned LLM for cleanup. Phase 0's exit criterion is
"headless core transcribes a WAV → cleaned text"; the highest-risk items are insertion and ASR
latency, not cleanup quality. Bundling/quantizing an LLM is meaningful integration work that
§32 sequences after the spine is proven.

## Decision
Ship Phase 0 with a deterministic `RuleCleanup` engine behind the `CleanupEngine` trait:
filler-word removal (uh/um/erm/hmm + configurable), whitespace normalization, sentence
capitalization, terminal punctuation, verbatim passthrough mode. The §17.2 hallucination guard
(length-ratio + content-word-retention check with lightly-cleaned-verbatim fallback) is
implemented now, in front of the trait, so it applies unchanged to the future LLM.

## Consequences
- Trait swap to a GGUF-quantized small LLM in Phase 1 requires no orchestrator changes.
- The guard is tested against a "malicious" mock engine that invents/drops content.
- Tone adaptation (§7 F9) explicitly out of Phase-0 scope.
