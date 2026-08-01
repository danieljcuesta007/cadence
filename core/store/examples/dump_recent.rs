//! Read the last few utterances out of the live encrypted store, for diagnosing what the app
//! actually recorded (language, app, text) rather than what it was supposed to record.
//!
//! The key lives in the login keychain, so this shells out to `security` rather than linking
//! Security.framework — the point is a debugging aid, not a product surface.
//!
//! Run: cargo run --example dump_recent -p cadence-store -- [LIMIT]

fn main() {
    let limit: usize = std::env::args()
        .nth(1)
        .and_then(|s| s.parse().ok())
        .unwrap_or(5);

    let home = std::env::var("HOME").expect("HOME");
    let db = format!("{home}/.cadence/store.db");

    let out = std::process::Command::new("security")
        .args([
            "find-generic-password", "-s", "dev.cadence.app", "-a", "store-key", "-w",
        ])
        .output()
        .expect("run security");
    if !out.status.success() {
        eprintln!("keychain read failed: {}", String::from_utf8_lossy(&out.stderr));
        std::process::exit(1);
    }
    // `security -w` prints the raw bytes hex-encoded when they are not valid UTF-8.
    let hex = String::from_utf8_lossy(&out.stdout).trim().to_string();
    let key: Vec<u8> = (0..hex.len())
        .step_by(2)
        .filter_map(|i| u8::from_str_radix(hex.get(i..i + 2)?, 16).ok())
        .collect();
    if key.len() != 32 {
        eprintln!("expected a 32-byte key, got {} bytes from `{hex}`", key.len());
        std::process::exit(1);
    }

    let store = cadence_store::Store::open(&db, &key).expect("open store");
    for k in ["custom_vocabulary", "dictation_language", "secondary_language"] {
        println!("setting {k} = {:?}", store.get_setting(k).ok().flatten().unwrap_or_default());
    }
    println!("---");
    for u in store.recent_utterances(limit).expect("read") {
        println!(
            "{}  lang={:<6} app={:<16} ok={:<5} {:?}",
            u.created_at_ms,
            u.language.clone().unwrap_or_else(|| "-".into()),
            u.app_bundle_id.clone().unwrap_or_else(|| "-".into()),
            u.inserted_ok,
            u.output_text.clone().unwrap_or_default()
        );
    }
}
