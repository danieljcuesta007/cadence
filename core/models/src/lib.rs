//! cadence-models — model lifecycle & integrity (§17.5, §24 `models` table).
//!
//! Phase 1 scope: a registry of local ASR/cleanup models, each pinned to a SHA-256, with
//! integrity **verification before use** and **client-side rollback to the bundled golden
//! model** when a versioned model is missing or corrupt (§17.5, §29 "Model missing/corrupt →
//! roll back to bundled golden model"). Hashing is dependency-free ([`sha256`]); asymmetric
//! signatures are a later enhancement (needs a signing key) — a pinned hash is the Phase-1
//! integrity gate, matching `models/fetch-models.sh`.
//!
//! Storage-agnostic: the registry is a plain in-memory list persisted through a [`ModelStore`]
//! so the encrypted SQLite store (§24) can back it later without touching this logic. A
//! file-based [`JsonManifestStore`] covers the pre-store phase.

pub mod sha256;

use std::fs::File;
use std::io::Read;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::sha256::{to_hex, Sha256};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ModelRole {
    Asr,
    Cleanup,
}

/// One row of the §24 `models` registry.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ModelEntry {
    pub id: String,
    pub role: ModelRole,
    pub version: String,
    pub path: PathBuf,
    /// Lowercase hex SHA-256 the file must match to be trusted.
    pub sha256: String,
    /// Expected file size in bytes; 0 = unknown/skip.
    pub size_bytes: u64,
    /// The currently-selected model for its role.
    pub active: bool,
    /// Bundled golden fallback (§17.5) — always present, the rollback target.
    pub bundled: bool,
}

#[derive(Debug, Error, PartialEq, Eq)]
pub enum ModelError {
    #[error("no model registered for role {0:?}")]
    NotFound(ModelRole),
    #[error("no bundled golden model for role {0:?} to roll back to")]
    NoGolden(ModelRole),
    #[error("hash mismatch for model {id}: expected {expected}, got {actual}")]
    HashMismatch {
        id: String,
        expected: String,
        actual: String,
    },
    #[error("size mismatch for model {id}: expected {expected} bytes, got {actual}")]
    SizeMismatch {
        id: String,
        expected: u64,
        actual: u64,
    },
    #[error("io error reading {path}: {msg}")]
    Io { path: String, msg: String },
}

/// Persistence seam so the encrypted SQLite store (§24) can back the registry later.
pub trait ModelStore {
    fn load(&self) -> Result<Vec<ModelEntry>, ModelError>;
    fn save(&self, entries: &[ModelEntry]) -> Result<(), ModelError>;
}

/// A JSON manifest on disk — the pre-SQLite backing store.
pub struct JsonManifestStore {
    pub path: PathBuf,
}

impl JsonManifestStore {
    pub fn new(path: impl Into<PathBuf>) -> Self {
        Self { path: path.into() }
    }
}

impl ModelStore for JsonManifestStore {
    fn load(&self) -> Result<Vec<ModelEntry>, ModelError> {
        let bytes = std::fs::read(&self.path).map_err(|e| ModelError::Io {
            path: self.path.display().to_string(),
            msg: e.to_string(),
        })?;
        serde_json::from_slice(&bytes).map_err(|e| ModelError::Io {
            path: self.path.display().to_string(),
            msg: format!("manifest parse: {e}"),
        })
    }

    fn save(&self, entries: &[ModelEntry]) -> Result<(), ModelError> {
        let json = serde_json::to_vec_pretty(entries).map_err(|e| ModelError::Io {
            path: self.path.display().to_string(),
            msg: format!("manifest serialize: {e}"),
        })?;
        std::fs::write(&self.path, json).map_err(|e| ModelError::Io {
            path: self.path.display().to_string(),
            msg: e.to_string(),
        })
    }
}

/// Stream a file through SHA-256 in bounded memory (models are ~140 MB).
pub fn sha256_file(path: &Path) -> Result<String, ModelError> {
    let mut file = File::open(path).map_err(|e| ModelError::Io {
        path: path.display().to_string(),
        msg: e.to_string(),
    })?;
    let mut hasher = Sha256::new();
    let mut buf = [0u8; 64 * 1024];
    loop {
        let n = file.read(&mut buf).map_err(|e| ModelError::Io {
            path: path.display().to_string(),
            msg: e.to_string(),
        })?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
    }
    Ok(to_hex(&hasher.finalize()))
}

pub struct ModelRegistry {
    entries: Vec<ModelEntry>,
}

impl ModelRegistry {
    pub fn new(entries: Vec<ModelEntry>) -> Self {
        Self { entries }
    }

    pub fn from_store(store: &dyn ModelStore) -> Result<Self, ModelError> {
        Ok(Self::new(store.load()?))
    }

    pub fn persist(&self, store: &dyn ModelStore) -> Result<(), ModelError> {
        store.save(&self.entries)
    }

    pub fn entries(&self) -> &[ModelEntry] {
        &self.entries
    }

    pub fn active(&self, role: ModelRole) -> Option<&ModelEntry> {
        self.entries.iter().find(|e| e.role == role && e.active)
    }

    pub fn golden(&self, role: ModelRole) -> Option<&ModelEntry> {
        self.entries.iter().find(|e| e.role == role && e.bundled)
    }

    /// Verify a model file against its pinned size + hash. Streams the file, so it's O(1) memory
    /// but O(file) time — call it at load, not per dictation.
    pub fn verify(entry: &ModelEntry) -> Result<(), ModelError> {
        if entry.size_bytes > 0 {
            let meta = std::fs::metadata(&entry.path).map_err(|e| ModelError::Io {
                path: entry.path.display().to_string(),
                msg: e.to_string(),
            })?;
            if meta.len() != entry.size_bytes {
                return Err(ModelError::SizeMismatch {
                    id: entry.id.clone(),
                    expected: entry.size_bytes,
                    actual: meta.len(),
                });
            }
        }
        let actual = sha256_file(&entry.path)?;
        if actual != entry.sha256 {
            return Err(ModelError::HashMismatch {
                id: entry.id.clone(),
                expected: entry.sha256.clone(),
                actual,
            });
        }
        Ok(())
    }

    /// Resolve the trusted file path for `role`: verify the active model; on any integrity
    /// failure, **quarantine it and roll back to the bundled golden** (§17.5, §29), then return
    /// the golden path. Mutates `active` flags so a subsequent [`persist`](Self::persist) records
    /// the rollback. Returns the path plus whether a rollback happened (for the "restored a
    /// working model" notice).
    pub fn resolve_verified(
        &mut self,
        role: ModelRole,
    ) -> Result<(PathBuf, bool), ModelError> {
        let active_idx = self.entries.iter().position(|e| e.role == role && e.active);

        if let Some(idx) = active_idx {
            match Self::verify(&self.entries[idx]) {
                Ok(()) => return Ok((self.entries[idx].path.clone(), false)),
                Err(ModelError::HashMismatch { .. } | ModelError::SizeMismatch { .. })
                | Err(ModelError::Io { .. }) => {
                    // Corrupt/missing active model: quarantine and fall through to golden.
                    if !self.entries[idx].bundled {
                        self.entries[idx].active = false;
                    }
                }
                Err(e) => return Err(e),
            }
        } else if self.golden(role).is_none() {
            return Err(ModelError::NotFound(role));
        }

        // Roll back to the bundled golden for this role.
        let golden_idx = self
            .entries
            .iter()
            .position(|e| e.role == role && e.bundled)
            .ok_or(ModelError::NoGolden(role))?;
        Self::verify(&self.entries[golden_idx])?;
        for (i, e) in self.entries.iter_mut().enumerate() {
            if e.role == role {
                e.active = i == golden_idx;
            }
        }
        Ok((self.entries[golden_idx].path.clone(), true))
    }
}
