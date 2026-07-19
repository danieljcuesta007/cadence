//! End-to-end headless pipeline tests: PCM → orchestrator → ASR → cleanup → insertion.

use cadence_asr::{AsrEngine, AsrError, MockAsr};
use cadence_cleanup::{Guarded, RuleCleanup};
use cadence_ipc::{Mode, ProcessingPolicy, Transcript};
use cadence_orchestrator::{CollectSink, Pipeline, DEFAULT_TAIL_WINDOW_SAMPLES};

fn tone(samples: usize) -> Vec<i16> {
    (0..samples)
        .map(|i| ((i as f32 * 0.1).sin() * 8000.0) as i16)
        .collect()
}

/// Records the size of every window handed to each pass, so tests can pin the sliding-tail
/// contract: partials stay O(tail) on long dictations while the refined pass sees everything.
struct RecordingAsr {
    partial_windows: Vec<usize>,
    refined_windows: Vec<usize>,
}

impl AsrEngine for RecordingAsr {
    fn transcribe(&mut self, pcm: &[f32]) -> Result<Transcript, AsrError> {
        self.refined_windows.push(pcm.len());
        Ok(Transcript {
            instant: None,
            refined: "long dictation".into(),
            language: Some("en".into()),
        })
    }

    fn transcribe_partial(&mut self, pcm: &[f32]) -> Result<Transcript, AsrError> {
        self.partial_windows.push(pcm.len());
        Ok(Transcript {
            instant: Some("partial".into()),
            refined: "partial".into(),
            language: Some("en".into()),
        })
    }
}

#[test]
fn long_dictation_partials_decode_only_the_tail() {
    let mut asr = RecordingAsr {
        partial_windows: Vec::new(),
        refined_windows: Vec::new(),
    };
    let cleanup = Guarded::new(RuleCleanup::default());
    let mut sink = CollectSink::default();
    let total = 16_000 * 30; // 30 s utterance, well past the 8 s tail
    let mut p = Pipeline::new(total, &mut asr, &cleanup, &mut sink);

    let report = p.run_utterance(&tone(total), Mode::Dictation, ProcessingPolicy::LocalOnly);

    assert!(report.inserted);
    assert!(
        asr.partial_windows.len() > 10,
        "expected a stream of partials, got {}",
        asr.partial_windows.len()
    );
    let widest = *asr.partial_windows.iter().max().unwrap();
    assert!(
        widest <= DEFAULT_TAIL_WINDOW_SAMPLES,
        "partial decoded {widest} samples — past the {DEFAULT_TAIL_WINDOW_SAMPLES} tail cap"
    );
    // Early partials (window still shorter than the tail) must NOT be truncated.
    assert!(asr.partial_windows[0] < DEFAULT_TAIL_WINDOW_SAMPLES);
    // The refined pass is authoritative: it sees the complete utterance exactly once.
    assert_eq!(asr.refined_windows, vec![total]);
}

#[test]
fn wav_window_to_cleaned_inserted_text() {
    let mut asr = MockAsr {
        refined: "um so this is uh the phase zero pipeline".into(),
    };
    let cleanup = Guarded::new(RuleCleanup::default());
    let mut sink = CollectSink::default();
    let mut p = Pipeline::new(16_000 * 30, &mut asr, &cleanup, &mut sink);

    let report = p.run_utterance(&tone(16_000), Mode::Dictation, ProcessingPolicy::LocalOnly);

    assert!(report.inserted);
    assert_eq!(
        report.final_text.as_deref(),
        Some("So this is the phase zero pipeline.")
    );
    assert_eq!(report.dropped_samples, 0, "no lost words");
    let privacy = report.privacy.unwrap();
    assert!(!privacy.data_left_device);
    assert_eq!(
        sink.inserted,
        vec!["So this is the phase zero pipeline.".to_string()]
    );
}

#[test]
fn verbatim_pipeline_inserts_literal_words() {
    let mut asr = MockAsr {
        refined: "um exactly this".into(),
    };
    let cleanup = Guarded::new(RuleCleanup::default());
    let mut sink = CollectSink::default();
    let mut p = Pipeline::new(16_000 * 30, &mut asr, &cleanup, &mut sink);

    let report = p.run_utterance(&tone(8_000), Mode::Verbatim, ProcessingPolicy::LocalOnly);
    assert_eq!(report.final_text.as_deref(), Some("um exactly this"));
}

#[test]
fn empty_audio_inserts_nothing() {
    let mut asr = MockAsr {
        refined: "never used".into(),
    };
    let cleanup = Guarded::new(RuleCleanup::default());
    let mut sink = CollectSink::default();
    let mut p = Pipeline::new(16_000 * 30, &mut asr, &cleanup, &mut sink);

    let report = p.run_utterance(&[], Mode::Dictation, ProcessingPolicy::LocalOnly);
    assert!(!report.inserted);
    assert!(sink.inserted.is_empty());
}

#[test]
fn instant_pass_emits_partials_before_the_refined_insert() {
    // §12.3 two-pass: partials surface while capturing; the refined/cleaned text still lands.
    // MockAsr's default transcribe_partial echoes its refined text, so each partial is the raw
    // (uncleaned) transcript — enough to prove the instant pass fired and was routed.
    let mut asr = MockAsr {
        refined: "um so this is uh the phase zero pipeline".into(),
    };
    let cleanup = Guarded::new(RuleCleanup::default());
    let mut sink = CollectSink::default();
    let mut p = Pipeline::new(16_000 * 30, &mut asr, &cleanup, &mut sink);

    // 2 s of audio → several 0.4 s partial strides.
    let report = p.run_utterance(&tone(32_000), Mode::Dictation, ProcessingPolicy::LocalOnly);

    assert!(
        !report.partials.is_empty(),
        "instant pass produced no partials"
    );
    assert!(
        report
            .partials
            .iter()
            .all(|t| t == "um so this is uh the phase zero pipeline"),
        "partials carried unexpected text: {:?}",
        report.partials
    );
    // Refined pass is still authoritative and cleaned.
    assert_eq!(
        report.final_text.as_deref(),
        Some("So this is the phase zero pipeline.")
    );
    assert!(report.inserted);
}

#[test]
fn no_partials_for_a_sub_min_window_utterance() {
    // Shorter than the instant-pass min window: no partial should fire, refined pass unaffected.
    let mut asr = MockAsr {
        refined: "quick".into(),
    };
    let cleanup = Guarded::new(RuleCleanup::default());
    let mut sink = CollectSink::default();
    let mut p = Pipeline::new(16_000 * 30, &mut asr, &cleanup, &mut sink);

    let report = p.run_utterance(&tone(3_200), Mode::Dictation, ProcessingPolicy::LocalOnly);
    assert!(report.partials.is_empty(), "unexpected partials: {:?}", report.partials);
    assert!(report.inserted);
}

#[test]
fn ring_capacity_overflow_keeps_freshest_speech_and_reports_drops() {
    // A ring smaller than the utterance: oldest samples drop, freshest survive, drops counted.
    let mut asr = MockAsr {
        refined: "tail words".into(),
    };
    let cleanup = Guarded::new(RuleCleanup::default());
    let mut sink = CollectSink::default();
    let mut p = Pipeline::new(4_000, &mut asr, &cleanup, &mut sink);

    let report = p.run_utterance(&tone(16_000), Mode::Dictation, ProcessingPolicy::LocalOnly);
    assert!(report.inserted);
    assert_eq!(report.dropped_samples, 12_000);
}
