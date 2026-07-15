//! cadence-headless — Phase-0 exit-criterion driver: WAV in → cleaned text out, through the
//! real orchestrator + engines, headlessly (§32 Phase 0).
//!
//! Usage:
//!   cadence-headless --wav path/to/16khz-mono.wav [--verbatim] [--mock "text"] [--model path]
//!
//! With the `whisper` feature + a model, ASR is real (whisper.cpp, Metal). `--mock` substitutes
//! a deterministic ASR for machines without a model.

use std::process::ExitCode;

use cadence_asr::{AsrEngine, MockAsr};
use cadence_cleanup::{Guarded, RuleCleanup};
use cadence_ipc::{Mode, ProcessingPolicy};
use cadence_orchestrator::{CollectSink, Pipeline};

struct Args {
    wav: Option<String>,
    verbatim: bool,
    mock: Option<String>,
    model: String,
}

fn parse_args() -> Args {
    let mut args = Args {
        wav: None,
        verbatim: false,
        mock: None,
        model: std::env::var("CADENCE_MODEL")
            .unwrap_or_else(|_| "models/artifacts/ggml-base.en.bin".into()),
    };
    let mut it = std::env::args().skip(1);
    while let Some(a) = it.next() {
        match a.as_str() {
            "--wav" => args.wav = it.next(),
            "--verbatim" => args.verbatim = true,
            "--mock" => args.mock = it.next(),
            "--model" => {
                if let Some(m) = it.next() {
                    args.model = m;
                }
            }
            _ => {}
        }
    }
    args
}

fn read_wav_16k_mono(path: &str) -> Result<Vec<i16>, String> {
    let mut reader = hound::WavReader::open(path).map_err(|e| format!("open {path}: {e}"))?;
    let spec = reader.spec();
    if spec.channels != 1 || spec.sample_rate != 16_000 {
        return Err(format!(
            "expected 16 kHz mono PCM, got {} Hz / {} ch (resample first)",
            spec.sample_rate, spec.channels
        ));
    }
    match (spec.sample_format, spec.bits_per_sample) {
        (hound::SampleFormat::Int, 16) => reader
            .samples::<i16>()
            .collect::<Result<Vec<_>, _>>()
            .map_err(|e| format!("read samples: {e}")),
        other => Err(format!("unsupported sample format {other:?}")),
    }
}

fn main() -> ExitCode {
    let args = parse_args();
    let Some(wav) = args.wav.as_deref() else {
        eprintln!("usage: cadence-headless --wav <16khz-mono.wav> [--verbatim] [--mock \"text\"] [--model <ggml.bin>]");
        return ExitCode::from(2);
    };

    let pcm = match read_wav_16k_mono(wav) {
        Ok(p) => p,
        Err(e) => {
            eprintln!("error: {e}");
            return ExitCode::FAILURE;
        }
    };

    let mut asr: Box<dyn AsrEngine> = if let Some(text) = args.mock {
        Box::new(MockAsr { refined: text })
    } else {
        #[cfg(feature = "whisper")]
        {
            match cadence_asr::whisper::WhisperAsr::load(&args.model) {
                Ok(w) => Box::new(w),
                Err(e) => {
                    eprintln!("error: failed to load model {}: {e}", args.model);
                    return ExitCode::FAILURE;
                }
            }
        }
        #[cfg(not(feature = "whisper"))]
        {
            eprintln!(
                "error: built without the `whisper` feature and no --mock given.\n\
                 rebuild with: cargo run -p cadence-headless --features whisper"
            );
            return ExitCode::FAILURE;
        }
    };

    let cleanup = Guarded::new(RuleCleanup::default());
    let mut sink = CollectSink::default();
    // 30 s ring at 16 kHz — matches the capture window budget for PTT utterances.
    let mut pipeline = Pipeline::new(16_000 * 30, asr.as_mut(), &cleanup, &mut sink);

    let mode = if args.verbatim {
        Mode::Verbatim
    } else {
        Mode::Dictation
    };
    let report = pipeline.run_utterance(&pcm, mode, ProcessingPolicy::LocalOnly);

    let summary = serde_json::json!({
        "wav": wav,
        "audio_seconds": report.audio_samples as f64 / 16_000.0,
        "refined_transcript": report.refined_transcript,
        "final_text": report.final_text,
        "inserted": report.inserted,
        "dropped_samples": report.dropped_samples,
        "privacy": report.privacy.as_ref().map(|p| serde_json::json!({
            "data_left_device": p.data_left_device,
            "asr": p.asr_location,
            "cleanup": p.cleanup_location,
        })),
        "timings_ms": {
            "asr": report.timings.asr_ms,
            "cleanup": report.timings.cleanup_ms,
            "insertion": report.timings.insertion_ms,
            "total": report.timings.total_ms,
        },
    });
    println!("{}", serde_json::to_string_pretty(&summary).unwrap());

    if report.final_text.is_some() {
        ExitCode::SUCCESS
    } else {
        ExitCode::FAILURE
    }
}
