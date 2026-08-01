//! Runtime language-switch check. The menu/hotkey path calls `set_language` on a *live* engine;
//! the only thing ever verified before was the `CADENCE_LANG` env path, which sets the same
//! field at construction. This exercises the setter the app actually uses, and — because the
//! personal dictionary rides the same decode as an `initial_prompt` — it also isolates whether
//! an English prompt drags Spanish audio into English.
//!
//! Run: cargo run --example lang_test --features whisper --release -- MODEL ES_WAV ["Dict, Terms"]

#[cfg(not(feature = "whisper"))]
fn main() {
    eprintln!("build with --features whisper");
}

#[cfg(feature = "whisper")]
fn main() {
    use cadence_asr::{whisper::WhisperAsr, AsrEngine};

    let mut args = std::env::args().skip(1);
    let model = args.next().expect("model path");
    let wav = args.next().expect("wav path");
    let dict = args.next().unwrap_or_default();

    let pcm = read_wav_i16_mono(&wav).expect("read wav");
    let f32pcm: Vec<f32> = pcm.iter().map(|&s| s as f32 / 32768.0).collect();

    let mut asr = WhisperAsr::load(&model).expect("load");

    // 1. Whatever the engine loaded with (CADENCE_LANG, default "auto").
    let base = asr.transcribe(&f32pcm).map(|t| t.refined).unwrap_or_default();
    println!("as-loaded      : {base}");

    // 2. The runtime setter, which is what a PTT key press does.
    asr.set_language("es");
    let pinned = asr.transcribe(&f32pcm).map(|t| t.refined).unwrap_or_default();
    println!("set_language es: {pinned}");

    // 3. Same pin, but with the dictionary prompt applied — the app always sets both.
    if !dict.is_empty() {
        asr.set_prompt(&dict);
        let with_dict = asr.transcribe(&f32pcm).map(|t| t.refined).unwrap_or_default();
        println!("es + dictionary: {with_dict}   (prompt: \"{dict}\")");
    }

    // 4. Back to English on the same live engine — proves the setter is not one-way.
    asr.set_prompt("");
    asr.set_language("en");
    let back = asr.transcribe(&f32pcm).map(|t| t.refined).unwrap_or_default();
    println!("set_language en: {back}");
}

#[cfg(feature = "whisper")]
fn read_wav_i16_mono(path: &str) -> std::io::Result<Vec<i16>> {
    use std::io::Read;
    let mut f = std::fs::File::open(path)?;
    let mut buf = Vec::new();
    f.read_to_end(&mut buf)?;
    let data = &buf[44..];
    Ok(data
        .chunks_exact(2)
        .map(|b| i16::from_le_bytes([b[0], b[1]]))
        .collect())
}
