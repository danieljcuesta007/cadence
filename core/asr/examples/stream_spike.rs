//! Streaming instant-pass ASR spike (§12.3 strategy B).
//!
//! Simulates the live path: feed a 16 kHz mono WAV in growing windows (as if the user were
//! still speaking) and run `transcribe_partial` on each window, recording per-step wall-clock
//! latency and the partial text. Then run the refined `transcribe` over the full utterance.
//! Sweeps `audio_ctx` (encoder length cap) to quantify the latency/coverage trade.
//!
//! Run: cargo run --example stream_spike --features whisper --release -- \
//!        models/artifacts/ggml-base.en.bin qa/fixtures/hello.wav
//!
//! Not a test — it needs a model on disk and prints a report for the spike write-up.

#[cfg(not(feature = "whisper"))]
fn main() {
    eprintln!("build with --features whisper (and --release for meaningful numbers)");
}

#[cfg(feature = "whisper")]
fn main() {
    use cadence_asr::{whisper::WhisperAsr, AsrEngine};
    use std::time::Instant;

    let mut args = std::env::args().skip(1);
    let model = args
        .next()
        .unwrap_or_else(|| "models/artifacts/ggml-base.en.bin".into());
    let wav = args
        .next()
        .unwrap_or_else(|| "qa/fixtures/hello.wav".into());

    let pcm = read_wav_i16_mono(&wav).unwrap_or_else(|e| panic!("read {wav}: {e}"));
    let secs = pcm.len() as f32 / 16_000.0;
    println!("# audio: {wav}  {:.2}s  ({} samples @16kHz)", secs, pcm.len());
    println!("# model: {model}\n");

    let load0 = Instant::now();
    let mut asr = WhisperAsr::load(&model).expect("model load");
    println!("model load: {} ms\n", load0.elapsed().as_millis());

    const STEP_S: f32 = 0.4; // emit a partial roughly every 400 ms of new audio
    let step = (STEP_S * 16_000.0) as usize;

    // audio_ctx in encoder frames (~50 per second). 0 = model default (1500 = 30 s).
    // 256 ≈ 5.1 s of coverage — plenty for a push-to-talk utterance, far cheaper to encode.
    for &audio_ctx in &[0i32, 512, 256] {
        asr.reset_stream();
        asr.set_partial_audio_ctx(audio_ctx);
        let label = if audio_ctx == 0 {
            "default(1500)".to_string()
        } else {
            audio_ctx.to_string()
        };
        println!("== instant pass, audio_ctx = {label} ==");

        let mut n = step;
        let mut worst = 0u128;
        loop {
            let end = n.min(pcm.len());
            let window = &pcm[..end];
            let t = Instant::now();
            let out = asr.transcribe_partial(window);
            let ms = t.elapsed().as_millis();
            worst = worst.max(ms);
            let text = match out {
                Ok(t) => t.instant.unwrap_or_default(),
                Err(e) => format!("<{e}>"),
            };
            println!(
                "  win {:>4.1}s  {:>4} ms  | {}",
                end as f32 / 16_000.0,
                ms,
                text
            );
            if end == pcm.len() {
                break;
            }
            n += step;
        }
        println!("  worst-step latency: {worst} ms\n");
    }

    // Refined (authoritative) pass over the whole utterance.
    asr.reset_stream();
    let t = Instant::now();
    let refined = asr.transcribe(&pcm).map(|t| t.refined).unwrap_or_default();
    println!("== refined pass ==");
    println!("  full {:.1}s  {} ms  | {}", secs, t.elapsed().as_millis(), refined);
}

/// Minimal canonical PCM16 mono WAV reader — enough for the fixtures (16 kHz, 1 ch, Int16).
/// Walks RIFF chunks to find `fmt ` and `data`; errors on anything non-PCM16-mono.
#[cfg(feature = "whisper")]
fn read_wav_i16_mono(path: &str) -> Result<Vec<f32>, String> {
    let bytes = std::fs::read(path).map_err(|e| e.to_string())?;
    if bytes.len() < 44 || &bytes[0..4] != b"RIFF" || &bytes[8..12] != b"WAVE" {
        return Err("not a RIFF/WAVE file".into());
    }
    let u16le = |o: usize| u16::from_le_bytes([bytes[o], bytes[o + 1]]);
    let u32le = |o: usize| u32::from_le_bytes([bytes[o], bytes[o + 1], bytes[o + 2], bytes[o + 3]]);

    let mut pos = 12;
    let (mut channels, mut rate, mut bits) = (0u16, 0u32, 0u16);
    let mut data: Option<(usize, usize)> = None;
    while pos + 8 <= bytes.len() {
        let id = &bytes[pos..pos + 4];
        let size = u32le(pos + 4) as usize;
        let body = pos + 8;
        match id {
            b"fmt " => {
                channels = u16le(body + 2);
                rate = u32le(body + 4);
                bits = u16le(body + 14);
            }
            b"data" => {
                data = Some((body, size.min(bytes.len() - body)));
            }
            _ => {}
        }
        pos = body + size + (size & 1); // chunks are word-aligned
    }
    if channels != 1 || rate != 16_000 || bits != 16 {
        return Err(format!("expected 16kHz/mono/16-bit, got {rate}Hz/{channels}ch/{bits}bit"));
    }
    let (off, len) = data.ok_or("no data chunk")?;
    let mut pcm = Vec::with_capacity(len / 2);
    let mut i = off;
    while i + 1 < off + len {
        let s = i16::from_le_bytes([bytes[i], bytes[i + 1]]);
        pcm.push(s as f32 / 32768.0);
        i += 2;
    }
    Ok(pcm)
}
