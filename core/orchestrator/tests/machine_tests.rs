//! Exhaustive transition tests for the orchestrator state machine (§12.2, §26, §29).

use cadence_ipc::*;
use cadence_orchestrator::Orchestrator;

fn utt(n: u64) -> UtteranceId {
    UtteranceId(format!("utt-{n}"))
}

fn transcript(s: &str) -> Transcript {
    Transcript {
        instant: None,
        refined: s.into(),
        language: Some("en".into()),
    }
}

fn ok_outcome() -> InsertionOutcome {
    InsertionOutcome {
        strategy: InsertionStrategy::Direct,
        inserted: true,
        clipboard_restored: true,
    }
}

fn has<F: Fn(&Effect) -> bool>(fx: &[Effect], pred: F) -> bool {
    fx.iter().any(pred)
}

/// Drive a machine to Thinking with one active utterance (id utt-1).
fn to_thinking(policy: ProcessingPolicy, mode: Mode) -> Orchestrator {
    let mut m = Orchestrator::new();
    m.handle(Event::TriggerDown { mode, policy });
    m.handle(Event::TriggerUp);
    assert_eq!(m.state(), State::Thinking);
    m
}

#[test]
fn happy_path_local_only() {
    let mut m = Orchestrator::new();

    let fx = m.handle(Event::TriggerDown {
        mode: Mode::Dictation,
        policy: ProcessingPolicy::LocalOnly,
    });
    assert_eq!(m.state(), State::Listening);
    assert!(has(&fx, |e| matches!(e, Effect::StartCapture { .. })));
    assert!(has(&fx, |e| matches!(
        e,
        Effect::PlaySound {
            sound: Sound::CaptureStart
        }
    )));
    assert!(has(&fx, |e| matches!(
        e,
        Effect::ShowOverlay {
            state: State::Listening,
            ..
        }
    )));

    let fx = m.handle(Event::TriggerUp);
    assert_eq!(m.state(), State::Thinking);
    assert!(has(&fx, |e| matches!(e, Effect::StopCapture)));
    assert!(has(&fx, |e| matches!(
        e,
        Effect::RunAsr {
            prefer: ProcessingLocation::Local,
            ..
        }
    )));

    let fx = m.handle(Event::AsrFinal {
        utterance: utt(1),
        transcript: transcript("hello world"),
        location: ProcessingLocation::Local,
    });
    assert!(has(&fx, |e| matches!(
        e,
        Effect::RunCleanup {
            verbatim: false,
            prefer: ProcessingLocation::Local,
            ..
        }
    )));

    let fx = m.handle(Event::CleanupDone {
        utterance: utt(1),
        text: "Hello world.".into(),
        location: ProcessingLocation::Local,
        guard_fallback: false,
    });
    assert_eq!(m.state(), State::Inserting);
    assert!(has(
        &fx,
        |e| matches!(e, Effect::RunInsertion { text, .. } if text == "Hello world.")
    ));

    let fx = m.handle(Event::InsertionCompleted {
        utterance: utt(1),
        outcome: ok_outcome(),
    });
    assert_eq!(m.state(), State::Idle);
    assert!(has(&fx, |e| matches!(e, Effect::ArmUndo { .. })));
    assert!(has(&fx, |e| matches!(
        e,
        Effect::ShowOverlay {
            state: State::Done,
            ..
        }
    )));
    assert!(has(&fx, |e| matches!(
        e,
        Effect::PersistUtterance { inserted: true, .. }
    )));

    let p = m.last_privacy().unwrap();
    assert!(
        !p.data_left_device,
        "local-only utterance must never leave the device"
    );
    assert_eq!(p.asr_location, Some(ProcessingLocation::Local));
}

#[test]
fn local_only_policy_never_prefers_cloud() {
    let mut m = to_thinking(ProcessingPolicy::LocalOnly, Mode::Dictation);
    let fx = m.handle(Event::AsrFinal {
        utterance: utt(1),
        transcript: transcript("x"),
        location: ProcessingLocation::Local,
    });
    assert!(has(&fx, |e| matches!(
        e,
        Effect::RunCleanup {
            prefer: ProcessingLocation::Local,
            ..
        }
    )));
}

#[test]
fn hybrid_prefers_cloud_until_degraded() {
    let mut m = Orchestrator::new();
    m.handle(Event::TriggerDown {
        mode: Mode::Dictation,
        policy: ProcessingPolicy::Hybrid,
    });
    let fx = m.handle(Event::TriggerUp);
    assert!(has(&fx, |e| matches!(
        e,
        Effect::RunAsr {
            prefer: ProcessingLocation::Cloud,
            ..
        }
    )));
}

#[test]
fn cloud_asr_failure_falls_back_local_and_chip_shows_local() {
    let mut m = to_thinking(ProcessingPolicy::Hybrid, Mode::Dictation);

    let fx = m.handle(Event::AsrFailed {
        utterance: utt(1),
        location: ProcessingLocation::Cloud,
        empty: false,
    });
    assert!(has(&fx, |e| matches!(
        e,
        Effect::RunAsr {
            prefer: ProcessingLocation::Local,
            ..
        }
    )));

    // Complete locally; per-utterance truth must say "local" (AC-24, AC-25).
    m.handle(Event::AsrFinal {
        utterance: utt(1),
        transcript: transcript("x"),
        location: ProcessingLocation::Local,
    });
    m.handle(Event::CleanupDone {
        utterance: utt(1),
        text: "X.".into(),
        location: ProcessingLocation::Local,
        guard_fallback: false,
    });
    m.handle(Event::InsertionCompleted {
        utterance: utt(1),
        outcome: ok_outcome(),
    });
    assert!(!m.last_privacy().unwrap().data_left_device);
}

#[test]
fn cloud_unavailable_mid_asr_reissues_locally() {
    let mut m = to_thinking(ProcessingPolicy::CloudPreferred, Mode::Dictation);
    let fx = m.handle(Event::CloudUnavailable);
    assert!(has(&fx, |e| matches!(
        e,
        Effect::RunAsr {
            prefer: ProcessingLocation::Local,
            ..
        }
    )));
    // Calm offline chip, still Thinking — not an error (§10.5).
    assert!(has(&fx, |e| matches!(
        e,
        Effect::ShowOverlay {
            state: State::Thinking,
            location_chip: Some(ProcessingLocation::Local)
        }
    )));
    assert_eq!(m.state(), State::Thinking);
}

#[test]
fn cloud_unavailable_mid_cleanup_reissues_locally_with_same_transcript() {
    let mut m = to_thinking(ProcessingPolicy::Hybrid, Mode::Dictation);
    m.handle(Event::AsrFinal {
        utterance: utt(1),
        transcript: transcript("keep these words"),
        location: ProcessingLocation::Cloud,
    });
    let fx = m.handle(Event::CloudUnavailable);
    assert!(has(&fx, |e| matches!(
        e,
        Effect::RunCleanup { transcript, prefer: ProcessingLocation::Local, .. }
            if transcript == "keep these words"
    )));
}

#[test]
fn cancel_during_listening_discards_everything() {
    let mut m = Orchestrator::new();
    m.handle(Event::TriggerDown {
        mode: Mode::Dictation,
        policy: ProcessingPolicy::Hybrid,
    });
    let fx = m.handle(Event::Cancel);
    assert_eq!(m.state(), State::Idle);
    assert!(has(&fx, |e| matches!(e, Effect::DiscardCapture)));
    assert!(has(&fx, |e| matches!(
        e,
        Effect::ShowOverlay {
            state: State::Cancelled,
            ..
        }
    )));
    assert!(!has(&fx, |e| matches!(e, Effect::RunInsertion { .. })));
}

#[test]
fn cancel_during_thinking_prevents_insertion_and_drops_stale_results() {
    let mut m = to_thinking(ProcessingPolicy::Hybrid, Mode::Dictation);
    m.handle(Event::Cancel);
    assert_eq!(m.state(), State::Idle);

    // A stale ASR result for the cancelled utterance must be ignored entirely.
    let fx = m.handle(Event::AsrFinal {
        utterance: utt(1),
        transcript: transcript("too late"),
        location: ProcessingLocation::Cloud,
    });
    assert!(fx.is_empty());
    assert_eq!(m.state(), State::Idle);
}

#[test]
fn stale_result_cannot_leak_into_next_utterance() {
    let mut m = to_thinking(ProcessingPolicy::Hybrid, Mode::Dictation);
    m.handle(Event::Cancel);

    // New utterance (utt-2) begins.
    m.handle(Event::TriggerDown {
        mode: Mode::Dictation,
        policy: ProcessingPolicy::Hybrid,
    });
    m.handle(Event::TriggerUp);

    // The old utterance's result arrives late: must be dropped.
    let fx = m.handle(Event::AsrFinal {
        utterance: utt(1),
        transcript: transcript("ghost of utterance one"),
        location: ProcessingLocation::Cloud,
    });
    assert!(fx.is_empty());

    // The right utterance's result still flows.
    let fx = m.handle(Event::AsrFinal {
        utterance: utt(2),
        transcript: transcript("real words"),
        location: ProcessingLocation::Local,
    });
    assert!(has(
        &fx,
        |e| matches!(e, Effect::RunCleanup { transcript, .. } if transcript == "real words")
    ));
}

#[test]
fn ptt_during_active_utterance_is_ignored() {
    let mut m = to_thinking(ProcessingPolicy::Hybrid, Mode::Dictation);
    let fx = m.handle(Event::TriggerDown {
        mode: Mode::Dictation,
        policy: ProcessingPolicy::Hybrid,
    });
    assert!(fx.is_empty(), "§26: single utterance at a time");
    assert_eq!(m.state(), State::Thinking);
}

#[test]
fn silence_produces_no_insertion_and_gentle_feedback() {
    let mut m = to_thinking(ProcessingPolicy::LocalOnly, Mode::Dictation);
    let fx = m.handle(Event::AsrFailed {
        utterance: utt(1),
        location: ProcessingLocation::Local,
        empty: true,
    });
    assert_eq!(m.state(), State::Idle);
    assert!(has(&fx, |e| matches!(
        e,
        Effect::PlaySound {
            sound: Sound::DidntCatchThat
        }
    )));
    assert!(!has(&fx, |e| matches!(e, Effect::RunInsertion { .. })));
}

#[test]
fn local_cleanup_failure_inserts_raw_transcript() {
    // P6/§29: cleanup failure must never cost the user their words.
    let mut m = to_thinking(ProcessingPolicy::LocalOnly, Mode::Dictation);
    m.handle(Event::AsrFinal {
        utterance: utt(1),
        transcript: transcript("precious words"),
        location: ProcessingLocation::Local,
    });
    let fx = m.handle(Event::CleanupFailed {
        utterance: utt(1),
        location: ProcessingLocation::Local,
    });
    assert_eq!(m.state(), State::Inserting);
    assert!(has(
        &fx,
        |e| matches!(e, Effect::RunInsertion { text, .. } if text == "precious words")
    ));
}

#[test]
fn cloud_cleanup_failure_retries_locally() {
    let mut m = to_thinking(ProcessingPolicy::Hybrid, Mode::Dictation);
    m.handle(Event::AsrFinal {
        utterance: utt(1),
        transcript: transcript("words"),
        location: ProcessingLocation::Cloud,
    });
    let fx = m.handle(Event::CleanupFailed {
        utterance: utt(1),
        location: ProcessingLocation::Cloud,
    });
    assert!(has(&fx, |e| matches!(
        e,
        Effect::RunCleanup {
            prefer: ProcessingLocation::Local,
            ..
        }
    )));
    assert_eq!(m.state(), State::Thinking);
}

#[test]
fn insertion_failure_preserves_words_on_clipboard() {
    let mut m = to_thinking(ProcessingPolicy::LocalOnly, Mode::Dictation);
    m.handle(Event::AsrFinal {
        utterance: utt(1),
        transcript: transcript("do not lose me"),
        location: ProcessingLocation::Local,
    });
    m.handle(Event::CleanupDone {
        utterance: utt(1),
        text: "Do not lose me.".into(),
        location: ProcessingLocation::Local,
        guard_fallback: false,
    });
    let fx = m.handle(Event::InsertionFailed { utterance: utt(1) });
    assert_eq!(m.state(), State::Idle);
    assert!(has(&fx, |e| matches!(
        e,
        Effect::NotifyTextOnClipboard { text } if text == "Do not lose me."
    )));
    assert!(has(&fx, |e| matches!(
        e,
        Effect::PersistUtterance {
            inserted: false,
            ..
        }
    )));
}

#[test]
fn user_interference_aborts_without_corruption() {
    let mut m = to_thinking(ProcessingPolicy::LocalOnly, Mode::Dictation);
    m.handle(Event::AsrFinal {
        utterance: utt(1),
        transcript: transcript("pending"),
        location: ProcessingLocation::Local,
    });
    m.handle(Event::CleanupDone {
        utterance: utt(1),
        text: "Pending.".into(),
        location: ProcessingLocation::Local,
        guard_fallback: false,
    });
    let fx = m.handle(Event::UserInterference { utterance: utt(1) });
    assert_eq!(m.state(), State::Idle);
    // §12.3: abandon the replacement, keep the user's edit, words stay recoverable.
    assert!(has(&fx, |e| matches!(
        e,
        Effect::NotifyTextOnClipboard { .. }
    )));
}

#[test]
fn clipboard_notify_outcome_notifies_and_persists_uninserted() {
    let mut m = to_thinking(ProcessingPolicy::LocalOnly, Mode::Dictation);
    m.handle(Event::AsrFinal {
        utterance: utt(1),
        transcript: transcript("terminal words"),
        location: ProcessingLocation::Local,
    });
    m.handle(Event::CleanupDone {
        utterance: utt(1),
        text: "Terminal words.".into(),
        location: ProcessingLocation::Local,
        guard_fallback: false,
    });
    let fx = m.handle(Event::InsertionCompleted {
        utterance: utt(1),
        outcome: InsertionOutcome {
            strategy: InsertionStrategy::ClipboardNotify,
            inserted: false,
            clipboard_restored: true,
        },
    });
    assert!(has(&fx, |e| matches!(
        e,
        Effect::NotifyTextOnClipboard { text } if text == "Terminal words."
    )));
    assert!(has(&fx, |e| matches!(
        e,
        Effect::PersistUtterance {
            inserted: false,
            ..
        }
    )));
}

#[test]
fn per_app_disable_blocks_dictation() {
    let mut m = Orchestrator::new();
    m.handle(Event::AppDisabled);
    assert_eq!(m.state(), State::Disabled);
    let fx = m.handle(Event::TriggerDown {
        mode: Mode::Dictation,
        policy: ProcessingPolicy::Hybrid,
    });
    assert!(fx.is_empty(), "AC-27: disabled app must not start capture");
    m.handle(Event::AppEnabled);
    assert_eq!(m.state(), State::Idle);
}

#[test]
fn verbatim_mode_propagates_to_cleanup() {
    let mut m = to_thinking(ProcessingPolicy::LocalOnly, Mode::Verbatim);
    let fx = m.handle(Event::AsrFinal {
        utterance: utt(1),
        transcript: transcript("um exactly as i said"),
        location: ProcessingLocation::Local,
    });
    assert!(has(&fx, |e| matches!(
        e,
        Effect::RunCleanup { verbatim: true, .. }
    )));
}

#[test]
fn cloud_utterance_reports_data_left_device() {
    let mut m = to_thinking(ProcessingPolicy::CloudPreferred, Mode::Dictation);
    m.handle(Event::AsrFinal {
        utterance: utt(1),
        transcript: transcript("x"),
        location: ProcessingLocation::Cloud,
    });
    m.handle(Event::CleanupDone {
        utterance: utt(1),
        text: "X.".into(),
        location: ProcessingLocation::Cloud,
        guard_fallback: false,
    });
    m.handle(Event::InsertionCompleted {
        utterance: utt(1),
        outcome: ok_outcome(),
    });
    let p = m.last_privacy().unwrap();
    assert!(p.data_left_device);
    assert_eq!(p.cleanup_location, Some(ProcessingLocation::Cloud));
}

#[test]
fn waveform_and_partials_only_while_listening() {
    let mut m = Orchestrator::new();
    assert!(m
        .handle(Event::AudioCaptured {
            samples: 10,
            level: 0.5
        })
        .is_empty());

    m.handle(Event::TriggerDown {
        mode: Mode::Dictation,
        policy: ProcessingPolicy::Hybrid,
    });
    let fx = m.handle(Event::AudioCaptured {
        samples: 10,
        level: 0.7,
    });
    assert!(has(&fx, |e| matches!(e, Effect::UpdateWaveform { .. })));
    let fx = m.handle(Event::AsrPartial {
        utterance: utt(1),
        text: "hel".into(),
    });
    assert!(has(&fx, |e| matches!(e, Effect::ShowPartial { .. })));

    m.handle(Event::TriggerUp);
    assert!(m
        .handle(Event::AudioCaptured {
            samples: 10,
            level: 0.5
        })
        .is_empty());
}
