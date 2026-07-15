# ADR-0007: Model integrity via dependency-free SHA-256 + registry rollback

**Status:** accepted · 2026-07-15

## Context
§17.5 requires models to be "verified by signature/hash, A/B-guarded (a bad model version can
be rolled back client-side)," with a bundled golden model so the app works offline on first
run. §29 spells out the failure path: *model missing/corrupt → roll back to bundled golden →
"Restored a working model" notice.* The §24 schema already defines a `models` table
(`id, role, version, path, hash, active, size_bytes`). `core/models` was an empty placeholder.

Two questions:
1. **What integrity primitive?** A full asymmetric signature (ed25519) needs a signing key and
   a crypto dependency. The environment is offline with no hashing crate cached, and the core
   crates are deliberately dependency-light. `models/fetch-models.sh` already pins a SHA-256.
2. **Where does verification/rollback live** so the eventual encrypted-SQLite store (§24) and
   the current pre-store phase both use the same logic?

## Decision
- **Integrity = pinned SHA-256, verified before use.** Signature (asymmetric) is deferred to
  when a signing key + distribution channel exist; a pinned hash is the correct Phase-1 gate and
  matches the fetch script. Implemented as a **dependency-free, streaming SHA-256**
  (`core/models/src/sha256.rs`) — no crypto crate, works offline, validated against the FIPS
  180-4 vectors *and* against the system `shasum` on the real 140 MB model (integration test
  `sha256_matches_pinned_model_hash`).
- **`ModelRegistry` owns verify + rollback**, storage-agnostic behind a `ModelStore` trait so
  the encrypted SQLite store plugs in later without touching the logic; a `JsonManifestStore`
  covers the pre-store phase. `resolve_verified(role)` verifies the active model, and on any
  hash/size/IO failure **quarantines it and rolls back to the bundled golden** (re-verified),
  returning `(path, rolled_back)` so the shell can show the §29 notice.
- **FFI gate:** `cadence_model_verify(path, expected_hex)` (C ABI) lets the shell check integrity
  before `cadence_engine_new`. Streams the file, so it's safe on a large model.

## Consequences / open
- **Idle model unload (<150 MB, §28/P8) is designed but not yet implemented.** It needs the FFI
  `Engine` to drop the `WhisperContext` after inactivity and lazy-reload on trigger — in direct
  tension with the ~7 s cold load measured in ADR-0006. Plan: unload only after a longer idle
  window, and reload eagerly on app-focus/hotkey-arm rather than on the latency-critical
  key-down. Tracked as the next §32.3 step; not done here to keep this increment verifiable.
- **Full registry-resolve over FFI** (manifest path + role → verified path with rollback) is a
  follow-on once the shell carries a manifest; today the shell passes a fixed model path, so the
  shipped surface is the `cadence_model_verify` gate plus the in-core registry/rollback logic.
- **Signature verification** remains a future enhancement layered above the hash gate.

## Reversibility
High. New leaf crate `cadence-models`; the FFI addition is one additive C function. The
`ModelStore` seam means swapping JSON→SQLite is local. No change to the ASR/orchestrator path.
