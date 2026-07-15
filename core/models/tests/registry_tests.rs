//! Registry verification + golden-rollback behavior (§17.5, §29), plus a real-file check that
//! the dependency-free SHA-256 agrees with the pinned model hash from `models/fetch-models.sh`.

use std::path::{Path, PathBuf};

use cadence_models::sha256::sha256_hex;
use cadence_models::{JsonManifestStore, ModelEntry, ModelError, ModelRegistry, ModelRole};

/// Write `content` to a uniquely-named temp file and return its path.
fn temp_file(tag: &str, content: &[u8]) -> PathBuf {
    let mut p = std::env::temp_dir();
    let uniq = format!(
        "cadence-models-test-{tag}-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    );
    p.push(uniq);
    std::fs::write(&p, content).unwrap();
    p
}

fn entry(id: &str, role: ModelRole, path: &Path, sha: &str, active: bool, bundled: bool) -> ModelEntry {
    ModelEntry {
        id: id.into(),
        role,
        version: "1".into(),
        path: path.to_path_buf(),
        sha256: sha.into(),
        size_bytes: 0,
        active,
        bundled,
    }
}

#[test]
fn verify_passes_for_matching_hash() {
    let content = b"a small pretend model";
    let path = temp_file("ok", content);
    let e = entry("m1", ModelRole::Asr, &path, &sha256_hex(content), true, false);
    assert_eq!(ModelRegistry::verify(&e), Ok(()));
    std::fs::remove_file(&path).ok();
}

#[test]
fn verify_fails_on_tampered_hash() {
    let content = b"the real bytes";
    let path = temp_file("tamper", content);
    let e = entry("m1", ModelRole::Asr, &path, &"0".repeat(64), true, false);
    match ModelRegistry::verify(&e) {
        Err(ModelError::HashMismatch { id, .. }) => assert_eq!(id, "m1"),
        other => panic!("expected HashMismatch, got {other:?}"),
    }
    std::fs::remove_file(&path).ok();
}

#[test]
fn verify_fails_on_size_mismatch_before_hashing() {
    let content = b"1234567890";
    let path = temp_file("size", content);
    let mut e = entry("m1", ModelRole::Asr, &path, &sha256_hex(content), true, false);
    e.size_bytes = 999; // wrong
    match ModelRegistry::verify(&e) {
        Err(ModelError::SizeMismatch { expected, actual, .. }) => {
            assert_eq!(expected, 999);
            assert_eq!(actual, content.len() as u64);
        }
        other => panic!("expected SizeMismatch, got {other:?}"),
    }
    std::fs::remove_file(&path).ok();
}

#[test]
fn corrupt_active_model_rolls_back_to_golden() {
    let good = b"golden bundled model";
    let updated = b"a newer downloaded model";
    let golden_path = temp_file("golden", good);
    let active_path = temp_file("active", updated);

    // The active (downloaded) model's registered hash is WRONG (simulating corruption/tamper);
    // the golden's is correct.
    let mut reg = ModelRegistry::new(vec![
        entry("golden-asr", ModelRole::Asr, &golden_path, &sha256_hex(good), false, true),
        entry("asr-v2", ModelRole::Asr, &active_path, &"f".repeat(64), true, false),
    ]);

    let (path, rolled_back) = reg.resolve_verified(ModelRole::Asr).unwrap();
    assert!(rolled_back, "should have rolled back");
    assert_eq!(path, golden_path);
    // The bad model is quarantined; golden is now active.
    assert_eq!(reg.active(ModelRole::Asr).unwrap().id, "golden-asr");
    assert!(!reg.entries().iter().find(|e| e.id == "asr-v2").unwrap().active);

    std::fs::remove_file(&golden_path).ok();
    std::fs::remove_file(&active_path).ok();
}

#[test]
fn healthy_active_model_resolves_without_rollback() {
    let bytes = b"healthy active model";
    let path = temp_file("healthy", bytes);
    let mut reg = ModelRegistry::new(vec![entry(
        "asr-v2",
        ModelRole::Asr,
        &path,
        &sha256_hex(bytes),
        true,
        false,
    )]);
    let (resolved, rolled_back) = reg.resolve_verified(ModelRole::Asr).unwrap();
    assert!(!rolled_back);
    assert_eq!(resolved, path);
    std::fs::remove_file(&path).ok();
}

#[test]
fn missing_role_errors() {
    let mut reg = ModelRegistry::new(vec![]);
    assert_eq!(
        reg.resolve_verified(ModelRole::Cleanup),
        Err(ModelError::NotFound(ModelRole::Cleanup))
    );
}

#[test]
fn json_manifest_round_trips() {
    let bytes = b"model bytes";
    let path = temp_file("manifest-model", bytes);
    let entries = vec![entry("g", ModelRole::Asr, &path, &sha256_hex(bytes), true, true)];

    let manifest = temp_file("manifest", b"[]");
    let store = JsonManifestStore::new(&manifest);
    let reg = ModelRegistry::new(entries.clone());
    reg.persist(&store).unwrap();

    let loaded = ModelRegistry::from_store(&store).unwrap();
    assert_eq!(loaded.entries(), entries.as_slice());

    std::fs::remove_file(&path).ok();
    std::fs::remove_file(&manifest).ok();
}

/// The pure-Rust SHA-256 must agree with the pinned hash the fetch script computed with the
/// system `shasum`. Skips if the (gitignored) model isn't present.
#[test]
fn sha256_matches_pinned_model_hash() {
    let model = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../models/artifacts/ggml-base.en.bin");
    if !model.exists() {
        eprintln!("skip: {} not present", model.display());
        return;
    }
    const PIN: &str = "a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002";
    assert_eq!(cadence_models::sha256_file(&model).unwrap(), PIN);
}
