/* cadence_ffi.h — C ABI for the Cadence core engine (§23, ADR-0005).
 *
 * Canonical copy lives in core/ffi/include/; platform shells import it via their
 * package plumbing (platform-macos/Core/CCadenceFFI symlinks here).
 *
 * Effects arrive on the callback as JSON in the cadence-ipc schema, one effect per
 * call, in order, on a core-owned thread — trampoline to your UI thread. Compute
 * effects (run_asr / run_cleanup) never cross this boundary; the shell only sees
 * presentation + insertion effects.
 */
#ifndef CADENCE_FFI_H
#define CADENCE_FFI_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct CadenceEngine CadenceEngine;

typedef void (*cadence_effect_cb)(const char *effect_json, void *ctx);

/* Engine backed by whisper.cpp at model_path (requires the core built with the
 * `whisper` feature). NULL on failure — see cadence_last_error(). */
CadenceEngine *cadence_engine_new(const char *model_path, cadence_effect_cb cb, void *ctx);

/* Engine with a deterministic mock ASR (tests / no model present). */
CadenceEngine *cadence_engine_new_mock(const char *refined_text, cadence_effect_cb cb, void *ctx);

/* Blocks briefly joining core threads; no callbacks fire after it returns. */
void cadence_engine_free(CadenceEngine *engine);

/* PTT lifecycle. Phase 1 policy is always local-only. */
void cadence_engine_trigger_down(CadenceEngine *engine, bool verbatim);
void cadence_engine_trigger_up(CadenceEngine *engine);
void cadence_engine_cancel(CadenceEngine *engine);

/* Set the dictation language at runtime: "auto" (detect per utterance; multilingual models
 * only), an ISO code like "en"/"es", or "" to leave the engine as loaded. Effective on the
 * next decode; no model reload; survives idle unload. */
void cadence_engine_set_language(CadenceEngine *engine, const char *lang);

/* Personal dictionary: bias decoding toward terms (proper nouns/jargon/names), passed as
 * whisper initial_prompt on the refined pass. "" clears it. Next decode; no reload. */
void cadence_engine_set_vocabulary(CadenceEngine *engine, const char *terms);

/* Confirm capture is stopped and the final audio buffer has been pushed. The core
 * holds the ASR window open for this (500 ms grace) so no trailing words are lost. */
void cadence_engine_capture_stopped(CadenceEngine *engine);

/* Append captured PCM (16 kHz mono i16). Audio-thread-safe. level in [0,1]. */
void cadence_engine_push_audio(CadenceEngine *engine, const int16_t *samples, size_t len,
                               float level);

/* Outcome of a run_insertion effect. strategy: "direct" | "tsf" | "paste_restore" |
 * "clipboard_notify" (ipc snake_case names). */
void cadence_engine_insertion_result(CadenceEngine *engine, const char *utterance_id,
                                     const char *strategy, bool inserted,
                                     bool clipboard_restored);
void cadence_engine_insertion_failed(CadenceEngine *engine, const char *utterance_id);

/* Verify a model file's SHA-256 against expected_sha256_hex (lowercase). Returns true iff it
 * matches; on mismatch/error returns false and sets cadence_last_error. Gate engine creation
 * on this before cadence_engine_new (model integrity, §17.5). Streams the file. */
bool cadence_model_verify(const char *model_path, const char *expected_sha256_hex);

/* ---- encrypted store (§24) ----------------------------------------------------------
 * SQLCipher-encrypted local history. The shell owns the 32-byte key (OS keychain) and
 * passes raw bytes at open; key material never persists in the core. */
typedef struct CadenceStore CadenceStore;

/* NULL on failure (wrong key included) — see cadence_last_error(). */
CadenceStore *cadence_store_open(const char *db_path, const uint8_t *key, size_t key_len);
void cadence_store_free(CadenceStore *store);

/* Persist one enriched history record (same JSON the JSONL stand-in received). On false,
 * the caller MUST fall back to JSONL so no words are lost (AC-22). */
bool cadence_store_persist_json(CadenceStore *store, const char *record_json);

/* Newest-first JSON array for the dashboard. Free with cadence_string_free. NULL on error. */
char *cadence_store_recent_json(CadenceStore *store, size_t limit);

/* One-time JSONL import; idempotent. Returns records imported, or -1 on failure. */
int64_t cadence_store_import_jsonl(CadenceStore *store, const char *jsonl_path);

/* Retention: purge utterances older than `days` (<=0 no-op). Rows purged, or -1. */
int64_t cadence_store_purge_utterances(CadenceStore *store, int64_t days);

/* Settings KV (§24). Get returns NULL when unset/error; free with cadence_string_free. */
char *cadence_store_setting_get(CadenceStore *store, const char *key);
bool cadence_store_setting_set(CadenceStore *store, const char *key, const char *value);

/* Retained audio (§24, opt-in; off by default). Blobs live inside the encrypted DB.
 * purge_after_ms: absolute epoch-ms deadline for the retention job; <=0 = no per-blob
 * deadline (the blob is purged with its utterance). */
bool cadence_store_audio_put(CadenceStore *store, const char *id, const uint8_t *data,
                             size_t data_len, int64_t purge_after_ms);
/* Delete a single utterance (and its audio blob) by id. Returns true if a row was removed. */
bool cadence_store_delete_utterance(CadenceStore *store, const char *id);

/* Malloc'd buffer (length via *out_len); free with cadence_bytes_free. NULL when absent. */
uint8_t *cadence_store_audio_get(CadenceStore *store, const char *id, size_t *out_len);
/* Hard delete + clears the utterance reference. True if a blob existed. */
bool cadence_store_audio_delete(CadenceStore *store, const char *id);
/* Purge blobs past purge_after; run at launch next to the utterance purge. -1 on error. */
int64_t cadence_store_audio_purge_expired(CadenceStore *store);
void cadence_bytes_free(uint8_t *ptr, size_t len);

void cadence_string_free(char *s);

/* Last error on the calling thread, or NULL. Valid until the next failing call. */
const char *cadence_last_error(void);
const char *cadence_version(void);

#ifdef __cplusplus
}
#endif

#endif /* CADENCE_FFI_H */
