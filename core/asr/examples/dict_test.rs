//! Personal-dictionary check: transcribe the same audio twice — bare, then with a term biased
//! via set_prompt — to confirm the initial_prompt path changes the spelling.
//!
//! Run: cargo run --example dict_test --features whisper --release -- MODEL WAV "Term, Term2"

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
    let prompt = args.next().unwrap_or_default();

    let pcm = read_wav_i16_mono(&wav).expect("read wav");
    let f32pcm: Vec<f32> = pcm.iter().map(|&s| s as f32 / 32768.0).collect();

    let mut asr = WhisperAsr::load(&model).expect("load");
    let bare = asr.transcribe(&f32pcm).map(|t| t.refined).unwrap_or_default();
    println!("bare:   {bare}");

    asr.set_prompt(&prompt);
    let biased = asr.transcribe(&f32pcm).map(|t| t.refined).unwrap_or_default();
    println!("biased: {biased}   (prompt: \"{prompt}\")");
}

#[cfg(feature = "whisper")]
fn read_wav_i16_mono(path: &str) -> std::io::Result<Vec<i16>> {
    use std::io::Read;
    let mut f = std::fs::File::open(path)?;
    let mut buf = Vec::new();
    f.read_to_end(&mut buf)?;
    // Minimal WAV: skip the 44-byte canonical header, read i16 LE samples.
    let data = &buf[44..];
    Ok(data
        .chunks_exact(2)
        .map(|b| i16::from_le_bytes([b[0], b[1]]))
        .collect())
}
