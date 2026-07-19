//! cadence-store — the encrypted local store (§24; blueprint "local data at rest").
//!
//! SQLCipher-encrypted SQLite. The key never lives here: the platform shell holds it in the
//! OS keychain and passes raw key bytes at open (hex-encoded into the `PRAGMA key` below).
//! Schema versioning via `PRAGMA user_version`; migrations are forward-only and idempotent
//! per version. This slice covers what the app writes today — utterance history, settings
//! KV, per-app rules, and the model-registry manifest — with the rest of the §24 tables
//! (dictionary, corrections, style, redaction, sync) landing with their features.
//!
//! AC-22 posture: an utterance INSERT failure must never lose words — callers keep the
//! JSONL fallback for exactly that error path.

use rusqlite::{params, Connection, OpenFlags};
use std::path::{Path, PathBuf};
use thiserror::Error;

pub const SCHEMA_VERSION: i64 = 2;

#[derive(Debug, Error)]
pub enum StoreError {
    #[error("store i/o: {0}")]
    Io(#[from] std::io::Error),
    #[error("sqlite: {0}")]
    Sqlite(#[from] rusqlite::Error),
    #[error("wrong key or not a cadence store: {0}")]
    BadKey(String),
    #[error("bad record: {0}")]
    BadRecord(String),
}

/// One dictation, as persisted. Mirrors the §24 `utterances` table; the shell's enriched
/// history record maps onto this via [`UtteranceRecord::from_json`].
#[derive(Debug, Clone, Default, PartialEq)]
pub struct UtteranceRecord {
    pub id: String,
    pub created_at_ms: i64,
    pub app_bundle_id: Option<String>,
    pub mode: Option<String>,
    pub processing_location: Option<String>,
    pub language: Option<String>,
    pub duration_ms: Option<i64>,
    pub transcript_instant: Option<String>,
    pub transcript_final: Option<String>,
    pub output_text: Option<String>,
    pub inserted_ok: bool,
    pub insertion_strategy: Option<String>,
    pub redacted: bool,
    pub word_count: Option<i64>,
    pub latency_ms: Option<i64>,
    /// Shell metrics that predate their own columns ride along as JSON (capture_start_ms…).
    pub extra_json: Option<String>,
}

impl UtteranceRecord {
    /// Build from the shell's history JSON (the enriched `persist_utterance` record).
    /// Unknown keys are preserved in `extra_json` so nothing the shell measures is dropped.
    pub fn from_json(json: &str) -> Result<Self, StoreError> {
        let v: serde_json::Value =
            serde_json::from_str(json).map_err(|e| StoreError::BadRecord(e.to_string()))?;
        let obj = v
            .as_object()
            .ok_or_else(|| StoreError::BadRecord("not a JSON object".into()))?;
        let s = |k: &str| obj.get(k).and_then(|x| x.as_str()).map(str::to_owned);
        let n = |k: &str| obj.get(k).and_then(serde_json::Value::as_i64);

        let text = s("text");
        let created_at_ms = obj
            .get("ts")
            .and_then(|x| x.as_str())
            .and_then(parse_iso8601_ms)
            .unwrap_or(0);

        let known = [
            "utterance",
            "ts",
            "app",
            "text",
            "location",
            "mode",
            "language",
            "inserted",
            "strategy",
            "capture_window_ms",
            "insertion_ms",
            "type",
            "redacted",
            "word_count",
            "latency_ms",
        ];
        let extra: serde_json::Map<String, serde_json::Value> = obj
            .iter()
            .filter(|(k, _)| !known.contains(&k.as_str()))
            .map(|(k, v)| (k.clone(), v.clone()))
            .collect();

        Ok(Self {
            id: s("utterance").unwrap_or_default(),
            created_at_ms,
            app_bundle_id: s("app"),
            mode: s("mode"),
            processing_location: s("location"),
            language: s("language"),
            duration_ms: n("capture_window_ms"),
            transcript_instant: None,
            transcript_final: None,
            word_count: n("word_count").or_else(|| {
                text.as_deref()
                    .map(|t| t.split_whitespace().count() as i64)
            }),
            output_text: text,
            inserted_ok: obj.get("inserted").and_then(|x| x.as_bool()).unwrap_or(false),
            insertion_strategy: s("strategy"),
            redacted: obj.get("redacted").and_then(|x| x.as_bool()).unwrap_or(false),
            latency_ms: n("insertion_ms"),
            extra_json: if extra.is_empty() {
                None
            } else {
                Some(serde_json::Value::Object(extra).to_string())
            },
        })
    }

    /// Serialize for the dashboard: same key names the JSONL reader already understands.
    pub fn to_json(&self) -> serde_json::Value {
        let mut o = serde_json::Map::new();
        let mut put = |k: &str, v: serde_json::Value| {
            if !v.is_null() {
                o.insert(k.into(), v);
            }
        };
        put("utterance", self.id.clone().into());
        put("ts", iso8601_from_ms(self.created_at_ms).into());
        put("app", self.app_bundle_id.clone().into());
        put("mode", self.mode.clone().into());
        put("location", self.processing_location.clone().into());
        put("language", self.language.clone().into());
        put("capture_window_ms", self.duration_ms.into());
        put("text", self.output_text.clone().into());
        put("inserted", self.inserted_ok.into());
        put("strategy", self.insertion_strategy.clone().into());
        put("word_count", self.word_count.into());
        put("insertion_ms", self.latency_ms.into());
        if let Some(extra) = self
            .extra_json
            .as_deref()
            .and_then(|e| serde_json::from_str::<serde_json::Map<_, _>>(e).ok())
        {
            for (k, v) in extra {
                o.entry(k).or_insert(v);
            }
        }
        serde_json::Value::Object(o)
    }
}

pub struct Store {
    conn: Connection,
    path: PathBuf,
}

impl Store {
    /// Open (creating if absent) the encrypted store. `key` is raw key material — 32 bytes
    /// from the OS keychain — applied as a SQLCipher raw hex key so no KDF phase is needed
    /// and opens stay fast. A wrong key surfaces as [`StoreError::BadKey`].
    pub fn open(path: impl AsRef<Path>, key: &[u8]) -> Result<Self, StoreError> {
        if key.len() != 32 {
            return Err(StoreError::BadKey(format!(
                "key must be 32 bytes, got {}",
                key.len()
            )));
        }
        if let Some(dir) = path.as_ref().parent() {
            std::fs::create_dir_all(dir)?;
        }
        let conn = Connection::open_with_flags(
            path.as_ref(),
            OpenFlags::SQLITE_OPEN_READ_WRITE | OpenFlags::SQLITE_OPEN_CREATE,
        )?;
        // SQLCipher raw-key form: x'<64 hex chars>'.
        let hex: String = key.iter().map(|b| format!("{b:02x}")).collect();
        conn.pragma_update(None, "key", format!("x'{hex}'"))?;
        // First real read both verifies the key and touches the header.
        let probe: Result<i64, _> =
            conn.query_row("SELECT count(*) FROM sqlite_master", [], |r| r.get(0));
        if let Err(e) = probe {
            return Err(StoreError::BadKey(e.to_string()));
        }
        conn.pragma_update(None, "journal_mode", "WAL")?;
        conn.pragma_update(None, "foreign_keys", "ON")?;
        let mut store = Self {
            conn,
            path: path.as_ref().to_owned(),
        };
        store.migrate()?;
        Ok(store)
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    fn migrate(&mut self) -> Result<(), StoreError> {
        let version: i64 = self
            .conn
            .query_row("PRAGMA user_version", [], |r| r.get(0))?;
        if version >= SCHEMA_VERSION {
            return Ok(());
        }
        let tx = self.conn.transaction()?;
        if version < 1 {
            tx.execute_batch(
                r#"
                CREATE TABLE IF NOT EXISTS utterances(
                    id TEXT PRIMARY KEY,
                    created_at INTEGER NOT NULL,
                    app_bundle_id TEXT,
                    mode TEXT,
                    processing_location TEXT,
                    language TEXT,
                    duration_ms INTEGER,
                    audio_blob_id TEXT,
                    transcript_instant TEXT,
                    transcript_final TEXT,
                    output_text TEXT,
                    inserted_ok INTEGER NOT NULL DEFAULT 0,
                    insertion_strategy TEXT,
                    redacted INTEGER NOT NULL DEFAULT 0,
                    word_count INTEGER,
                    latency_ms INTEGER,
                    extra_json TEXT
                );
                CREATE INDEX IF NOT EXISTS idx_utterances_created
                    ON utterances(created_at DESC);
                CREATE TABLE IF NOT EXISTS settings(
                    key TEXT PRIMARY KEY,
                    value TEXT
                );
                CREATE TABLE IF NOT EXISTS app_rules(
                    app_bundle_id TEXT PRIMARY KEY,
                    enabled INTEGER NOT NULL DEFAULT 1,
                    force_local INTEGER NOT NULL DEFAULT 0,
                    force_verbatim INTEGER NOT NULL DEFAULT 0,
                    default_mode TEXT,
                    context_allowed INTEGER NOT NULL DEFAULT 1
                );
                CREATE TABLE IF NOT EXISTS models(
                    id TEXT PRIMARY KEY,
                    role TEXT NOT NULL,
                    version TEXT NOT NULL,
                    path TEXT NOT NULL,
                    hash TEXT NOT NULL,
                    active INTEGER NOT NULL DEFAULT 0,
                    size_bytes INTEGER NOT NULL DEFAULT 0
                );
                "#,
            )?;
        }
        if version < 2 {
            // §17.5: the registry needs the bundled-golden flag to roll back to.
            tx.execute_batch(
                "ALTER TABLE models ADD COLUMN bundled INTEGER NOT NULL DEFAULT 0;",
            )?;
        }
        tx.pragma_update(None, "user_version", SCHEMA_VERSION)?;
        tx.commit()?;
        Ok(())
    }

    // ---- utterances -------------------------------------------------------------------

    pub fn insert_utterance(&self, rec: &UtteranceRecord) -> Result<(), StoreError> {
        if rec.id.is_empty() {
            return Err(StoreError::BadRecord("empty utterance id".into()));
        }
        self.conn.execute(
            r#"INSERT OR REPLACE INTO utterances
               (id, created_at, app_bundle_id, mode, processing_location, language,
                duration_ms, transcript_instant, transcript_final, output_text,
                inserted_ok, insertion_strategy, redacted, word_count, latency_ms, extra_json)
               VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16)"#,
            params![
                rec.id,
                rec.created_at_ms,
                rec.app_bundle_id,
                rec.mode,
                rec.processing_location,
                rec.language,
                rec.duration_ms,
                rec.transcript_instant,
                rec.transcript_final,
                rec.output_text,
                rec.inserted_ok as i64,
                rec.insertion_strategy,
                rec.redacted as i64,
                rec.word_count,
                rec.latency_ms,
                rec.extra_json,
            ],
        )?;
        Ok(())
    }

    pub fn recent_utterances(&self, limit: usize) -> Result<Vec<UtteranceRecord>, StoreError> {
        let mut stmt = self.conn.prepare(
            r#"SELECT id, created_at, app_bundle_id, mode, processing_location, language,
                      duration_ms, transcript_instant, transcript_final, output_text,
                      inserted_ok, insertion_strategy, redacted, word_count, latency_ms,
                      extra_json
               FROM utterances ORDER BY created_at DESC, rowid DESC LIMIT ?1"#,
        )?;
        let rows = stmt.query_map([limit as i64], |r| {
            Ok(UtteranceRecord {
                id: r.get(0)?,
                created_at_ms: r.get(1)?,
                app_bundle_id: r.get(2)?,
                mode: r.get(3)?,
                processing_location: r.get(4)?,
                language: r.get(5)?,
                duration_ms: r.get(6)?,
                transcript_instant: r.get(7)?,
                transcript_final: r.get(8)?,
                output_text: r.get(9)?,
                inserted_ok: r.get::<_, i64>(10)? != 0,
                insertion_strategy: r.get(11)?,
                redacted: r.get::<_, i64>(12)? != 0,
                word_count: r.get(13)?,
                latency_ms: r.get(14)?,
                extra_json: r.get(15)?,
            })
        })?;
        Ok(rows.collect::<Result<_, _>>()?)
    }

    pub fn utterance_count(&self) -> Result<i64, StoreError> {
        Ok(self
            .conn
            .query_row("SELECT count(*) FROM utterances", [], |r| r.get(0))?)
    }

    /// One-time migration from the JSONL stand-in. Idempotent: ids are disambiguated by
    /// timestamp (JSONL reuses utt-1, utt-2 … across sessions) and `INSERT OR REPLACE`
    /// makes a re-import converge instead of duplicating. Rows that fail to parse are
    /// skipped and counted, never fatal (AC-22: importing must not destroy anything — the
    /// caller renames the JSONL aside only after success).
    pub fn import_jsonl(&self, path: impl AsRef<Path>) -> Result<(usize, usize), StoreError> {
        let data = std::fs::read_to_string(path)?;
        let mut imported = 0usize;
        let mut skipped = 0usize;
        for (i, line) in data.lines().enumerate() {
            if line.trim().is_empty() {
                continue;
            }
            match UtteranceRecord::from_json(line) {
                Ok(mut rec) => {
                    if rec.id.is_empty() {
                        rec.id = format!("import-{i}");
                    }
                    rec.id = format!("{}-{}", rec.id, rec.created_at_ms);
                    self.insert_utterance(&rec)?;
                    imported += 1;
                }
                Err(_) => skipped += 1,
            }
        }
        Ok((imported, skipped))
    }

    /// Retention (§24/§ privacy: "configurable retention and auto-purge"): delete utterance
    /// rows older than `days`. Returns rows purged. Callers read the `retention_days`
    /// setting (0/absent = keep forever) and run this at open.
    pub fn purge_utterances_older_than_days(&self, days: i64) -> Result<usize, StoreError> {
        if days <= 0 {
            return Ok(0);
        }
        let cutoff_ms = now_ms() - days * 86_400_000;
        let n = self
            .conn
            .execute("DELETE FROM utterances WHERE created_at < ?1", [cutoff_ms])?;
        Ok(n)
    }

    // ---- settings ---------------------------------------------------------------------

    pub fn set_setting(&self, key: &str, value: &str) -> Result<(), StoreError> {
        self.conn.execute(
            "INSERT OR REPLACE INTO settings(key, value) VALUES (?1, ?2)",
            params![key, value],
        )?;
        Ok(())
    }

    pub fn get_setting(&self, key: &str) -> Result<Option<String>, StoreError> {
        use rusqlite::OptionalExtension;
        Ok(self
            .conn
            .query_row("SELECT value FROM settings WHERE key = ?1", [key], |r| {
                r.get(0)
            })
            .optional()?)
    }
}

/// §17.5/§24: the model registry persisted in the encrypted store — `ModelRegistry` plugs
/// in here in place of the JSON manifest. `save` replaces the whole set transactionally
/// (the registry owns the entries; partial writes would corrupt rollback state).
impl cadence_models::ModelStore for Store {
    fn load(&self) -> Result<Vec<cadence_models::ModelEntry>, cadence_models::ModelError> {
        let map_err = |e: rusqlite::Error| cadence_models::ModelError::Io {
            path: self.path.display().to_string(),
            msg: e.to_string(),
        };
        let mut stmt = self
            .conn
            .prepare(
                "SELECT id, role, version, path, hash, active, size_bytes, bundled
                 FROM models ORDER BY id",
            )
            .map_err(map_err)?;
        let rows = stmt
            .query_map([], |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    r.get::<_, String>(1)?,
                    r.get::<_, String>(2)?,
                    r.get::<_, String>(3)?,
                    r.get::<_, String>(4)?,
                    r.get::<_, i64>(5)?,
                    r.get::<_, i64>(6)?,
                    r.get::<_, i64>(7)?,
                ))
            })
            .map_err(map_err)?
            .collect::<Result<Vec<_>, _>>()
            .map_err(map_err)?;
        rows.into_iter()
            .map(|(id, role, version, path, sha256, active, size, bundled)| {
                let role = serde_json::from_value(serde_json::Value::String(role.clone()))
                    .map_err(|e| cadence_models::ModelError::Io {
                        path: self.path.display().to_string(),
                        msg: format!("bad role '{role}' for model {id}: {e}"),
                    })?;
                Ok(cadence_models::ModelEntry {
                    id,
                    role,
                    version,
                    path: PathBuf::from(path),
                    sha256,
                    size_bytes: size as u64,
                    active: active != 0,
                    bundled: bundled != 0,
                })
            })
            .collect()
    }

    fn save(
        &self,
        entries: &[cadence_models::ModelEntry],
    ) -> Result<(), cadence_models::ModelError> {
        let map_err = |e: rusqlite::Error| cadence_models::ModelError::Io {
            path: self.path.display().to_string(),
            msg: e.to_string(),
        };
        let tx = self.conn.unchecked_transaction().map_err(map_err)?;
        tx.execute("DELETE FROM models", []).map_err(map_err)?;
        for e in entries {
            let role = match serde_json::to_value(e.role) {
                Ok(serde_json::Value::String(s)) => s,
                _ => {
                    return Err(cadence_models::ModelError::Io {
                        path: self.path.display().to_string(),
                        msg: format!("unserializable role for model {}", e.id),
                    })
                }
            };
            tx.execute(
                "INSERT INTO models (id, role, version, path, hash, active, size_bytes, bundled)
                 VALUES (?1,?2,?3,?4,?5,?6,?7,?8)",
                params![
                    e.id,
                    role,
                    e.version,
                    e.path.display().to_string(),
                    e.sha256,
                    e.active as i64,
                    e.size_bytes as i64,
                    e.bundled as i64,
                ],
            )
            .map_err(map_err)?;
        }
        tx.commit().map_err(map_err)
    }
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

fn parse_iso8601_ms(s: &str) -> Option<i64> {
    // "2026-07-16T13:29:24Z" (whole seconds; the shell writes ISO8601DateFormatter output).
    let s = s.strip_suffix('Z')?;
    let (date, time) = s.split_once('T')?;
    let mut d = date.split('-');
    let (y, mo, da) = (
        d.next()?.parse::<i64>().ok()?,
        d.next()?.parse::<u32>().ok()?,
        d.next()?.parse::<u32>().ok()?,
    );
    let mut t = time.split(':');
    let (h, mi, sec) = (
        t.next()?.parse::<i64>().ok()?,
        t.next()?.parse::<i64>().ok()?,
        t.next()?.parse::<f64>().ok()?,
    );
    if !(1..=12).contains(&mo) || !(1..=31).contains(&da) {
        return None;
    }
    let days = days_from_civil(y, mo, da);
    Some(((days * 86_400 + h * 3_600 + mi * 60) as f64 * 1_000.0 + sec * 1_000.0) as i64)
}

fn iso8601_from_ms(ms: i64) -> String {
    let secs = ms.div_euclid(1_000);
    let days = secs.div_euclid(86_400);
    let rem = secs.rem_euclid(86_400);
    let (y, mo, da) = civil_from_days(days);
    format!(
        "{y:04}-{mo:02}-{da:02}T{:02}:{:02}:{:02}Z",
        rem / 3_600,
        (rem % 3_600) / 60,
        rem % 60
    )
}

// Howard Hinnant's civil-days algorithms (public domain): epoch day <-> y/m/d.
fn days_from_civil(y: i64, m: u32, d: u32) -> i64 {
    let y = y - i64::from(m <= 2);
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let doy = (153 * (m as i64 + if m > 2 { -3 } else { 9 }) + 2) / 5 + d as i64 - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

fn civil_from_days(z: i64) -> (i64, u32, u32) {
    let z = z + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = (if mp < 10 { mp + 3 } else { mp - 9 }) as u32;
    (y + i64::from(m <= 2), m, d)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn key() -> [u8; 32] {
        let mut k = [0u8; 32];
        for (i, b) in k.iter_mut().enumerate() {
            *b = i as u8 ^ 0x5a;
        }
        k
    }

    fn tmp(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("cadence-store-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        dir.join(name)
    }

    #[test]
    fn roundtrip_utterance() {
        let path = tmp("roundtrip.db");
        let _ = std::fs::remove_file(&path);
        let store = Store::open(&path, &key()).unwrap();
        let rec = UtteranceRecord {
            id: "utt-1-999".into(),
            created_at_ms: 1_789_000_000_000,
            app_bundle_id: Some("com.apple.TextEdit".into()),
            processing_location: Some("local".into()),
            output_text: Some("Hello from the encrypted store.".into()),
            inserted_ok: true,
            insertion_strategy: Some("direct".into()),
            word_count: Some(5),
            latency_ms: Some(32),
            extra_json: Some(r#"{"capture_start_ms":47}"#.into()),
            ..Default::default()
        };
        store.insert_utterance(&rec).unwrap();
        let back = store.recent_utterances(10).unwrap();
        assert_eq!(back, vec![rec]);
    }

    #[test]
    fn wrong_key_is_rejected_and_right_key_recovers() {
        let path = tmp("badkey.db");
        let _ = std::fs::remove_file(&path);
        {
            let store = Store::open(&path, &key()).unwrap();
            store.set_setting("earcons", "on").unwrap();
        }
        let mut wrong = key();
        wrong[0] ^= 0xff;
        match Store::open(&path, &wrong) {
            Err(StoreError::BadKey(_)) => {}
            Err(other) => panic!("wrong key must be BadKey, got {other:?}"),
            Ok(_) => panic!("wrong key must fail closed"),
        }
        let store = Store::open(&path, &key()).unwrap();
        assert_eq!(store.get_setting("earcons").unwrap().as_deref(), Some("on"));
    }

    #[test]
    fn db_bytes_are_not_plaintext() {
        let path = tmp("opaque.db");
        let _ = std::fs::remove_file(&path);
        let store = Store::open(&path, &key()).unwrap();
        let rec = UtteranceRecord {
            id: "utt-secret".into(),
            output_text: Some("EXTREMELY-DISTINCTIVE-PLAINTEXT".into()),
            ..Default::default()
        };
        store.insert_utterance(&rec).unwrap();
        // Force everything to the main db file, then check the raw bytes.
        store
            .conn
            .pragma_update(None, "wal_checkpoint", "TRUNCATE")
            .ok();
        drop(store);
        let raw = std::fs::read(&path).unwrap();
        assert!(!raw
            .windows(b"EXTREMELY-DISTINCTIVE-PLAINTEXT".len())
            .any(|w| w == b"EXTREMELY-DISTINCTIVE-PLAINTEXT"));
        assert!(!raw.starts_with(b"SQLite format 3"), "unencrypted header");
    }

    #[test]
    fn shell_json_maps_and_survives_import() {
        let line = r#"{"text":"Okay, so what are we going to write about today?","utterance":"utt-2","strategy":"direct","capture_window_ms":4066,"ts":"2026-07-16T13:29:33Z","location":"local","capture_start_ms":36,"inserted":true,"insertion_ms":51,"app":"Notes","type":"persist_utterance"}"#;
        let rec = UtteranceRecord::from_json(line).unwrap();
        assert_eq!(rec.id, "utt-2");
        assert_eq!(rec.app_bundle_id.as_deref(), Some("Notes"));
        assert_eq!(rec.duration_ms, Some(4066));
        assert_eq!(rec.latency_ms, Some(51));
        assert_eq!(rec.word_count, Some(10));
        assert!(rec.inserted_ok);
        // capture_start_ms survives via extra_json and resurfaces in to_json.
        let out = rec.to_json();
        assert_eq!(out["capture_start_ms"], 36);
        assert_eq!(out["ts"], "2026-07-16T13:29:33Z");

        let path = tmp("import.db");
        let _ = std::fs::remove_file(&path);
        let jsonl = tmp("history.jsonl");
        std::fs::write(&jsonl, format!("{line}\nnot-json\n{line}\n")).unwrap();
        let store = Store::open(&path, &key()).unwrap();
        let (imported, skipped) = store.import_jsonl(&jsonl).unwrap();
        assert_eq!((imported, skipped), (2, 1));
        // Same id+ts twice → converges to one row (idempotent re-import).
        assert_eq!(store.utterance_count().unwrap(), 1);
        let (again, _) = store.import_jsonl(&jsonl).unwrap();
        assert_eq!(again, 2);
        assert_eq!(store.utterance_count().unwrap(), 1);
    }

    #[test]
    fn retention_purges_only_old_rows() {
        let path = tmp("retention.db");
        let _ = std::fs::remove_file(&path);
        let store = Store::open(&path, &key()).unwrap();
        let old = UtteranceRecord {
            id: "old".into(),
            created_at_ms: now_ms() - 40 * 86_400_000,
            ..Default::default()
        };
        let recent = UtteranceRecord {
            id: "recent".into(),
            created_at_ms: now_ms() - 86_400_000,
            ..Default::default()
        };
        store.insert_utterance(&old).unwrap();
        store.insert_utterance(&recent).unwrap();
        assert_eq!(store.purge_utterances_older_than_days(30).unwrap(), 1);
        let left = store.recent_utterances(10).unwrap();
        assert_eq!(left.len(), 1);
        assert_eq!(left[0].id, "recent");
        // 0 = keep forever: a no-op by contract.
        assert_eq!(store.purge_utterances_older_than_days(0).unwrap(), 0);
    }

    #[test]
    fn model_registry_roundtrips_through_the_store() {
        use cadence_models::{ModelEntry, ModelRole, ModelStore as _};
        let path = tmp("models.db");
        let _ = std::fs::remove_file(&path);
        let store = Store::open(&path, &key()).unwrap();
        let entries = vec![
            ModelEntry {
                id: "base.en".into(),
                role: ModelRole::Asr,
                version: "1".into(),
                path: PathBuf::from("/models/ggml-base.en.bin"),
                sha256: "a".repeat(64),
                size_bytes: 147_964_211,
                active: true,
                bundled: true,
            },
            ModelEntry {
                id: "rules-v1".into(),
                role: ModelRole::Cleanup,
                version: "1".into(),
                path: PathBuf::from("/models/rules.bin"),
                sha256: "b".repeat(64),
                size_bytes: 0,
                active: false,
                bundled: false,
            },
        ];
        store.save(&entries).unwrap();
        let mut back = store.load().unwrap();
        back.sort_by(|a, b| a.id.cmp(&b.id));
        assert_eq!(back, entries);
        // save replaces wholesale (registry owns the set).
        store.save(&entries[..1]).unwrap();
        assert_eq!(store.load().unwrap().len(), 1);
    }

    #[test]
    fn iso8601_roundtrip() {
        for ts in ["2026-07-16T13:29:33Z", "2000-01-01T00:00:00Z", "1999-12-31T23:59:59Z"] {
            let ms = parse_iso8601_ms(ts).unwrap();
            assert_eq!(iso8601_from_ms(ms), ts, "roundtrip {ts}");
        }
        assert_eq!(parse_iso8601_ms("2026-07-16T13:29:33.500Z").unwrap() % 1000, 500);
        assert!(parse_iso8601_ms("garbage").is_none());
    }
}
