//! End-to-end headless pipeline tests: PCM → orchestrator → ASR → cleanup → insertion.

use cadence_asr::MockAsr;
use cadence_cleanup::{Guarded, RuleCleanup};
use cadence_ipc::{Mode, ProcessingPolicy};
use cadence_orchestrator::{CollectSink, Pipeline};

fn tone(samples: usize) -> Vec<i16> {
    (0..samples)
        .map(|i| ((i as f32 * 0.1).sin() * 8000.0) as i16)
        .collect()
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
