//! cadence-ipc — the typed schema shared between the Rust core and the native shells.
//!
//! This is the "Local IPC" source of truth from blueprint §23: every state, event, and effect
//! that crosses the core↔shell boundary is defined (and serde-serializable) here. The
//! orchestrator (§12.2, §26) consumes [`Event`]s and emits [`Effect`]s; shells translate OS
//! reality into events and render/execute effects.

use serde::{Deserialize, Serialize};

/// Monotonic-unique id for one utterance lifecycle (uuid v4 string per §24 schema).
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct UtteranceId(pub String);

/// Where processing for an utterance *actually* ran (§19 "per-utterance truth").
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ProcessingLocation {
    Local,
    Cloud,
}

/// The user-selected global processing policy (§19).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ProcessingPolicy {
    LocalOnly,
    Hybrid,
    CloudPreferred,
}

/// Dictation mode for an utterance (§24 `utterances.mode`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Mode {
    Dictation,
    Verbatim,
    Command,
}

/// Visible orchestrator states (§12.2).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum State {
    Idle,
    Listening,
    Thinking,
    Inserting,
    Done,
    Cancelled,
    Error,
    /// Dictation disabled for the focused app by a per-app rule (§7 F27).
    Disabled,
}

/// Insertion strategies, in cascade preference order (§7 F20, §12.3).
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum InsertionStrategy {
    /// Direct text-service API (macOS AX selected-text replace / Windows UIA TextPattern).
    Direct,
    /// Input-method path (marked text / TSF).
    Tsf,
    /// Synthetic paste with clipboard save+restore.
    PasteRestore,
    /// Terminal fallback: leave text on the clipboard and notify the user (§29).
    ClipboardNotify,
}

/// What the insertion engine reports back for one attempt.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct InsertionOutcome {
    pub strategy: InsertionStrategy,
    /// True iff text verifiably landed in the target (ClipboardNotify counts as `false`:
    /// the words are safe but did not land at the caret).
    pub inserted: bool,
    /// True iff the user's prior clipboard contents were restored (must always be true
    /// whenever the clipboard was touched — AC-20).
    pub clipboard_restored: bool,
}

/// Two-pass output of ASR (§17.1): instant partial then refined final.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Transcript {
    pub instant: Option<String>,
    pub refined: String,
    pub language: Option<String>,
}

/// Events fed INTO the orchestrator by shells / engine adapters.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Event {
    /// PTT key down (or hands-free start). Carries the mode + policy resolved for the
    /// focused app (per-app rules applied by the shell's rule lookup, §7 F27).
    TriggerDown {
        mode: Mode,
        policy: ProcessingPolicy,
    },
    /// PTT key released (or hands-free stop): finalize the utterance.
    TriggerUp,
    /// A chunk of captured PCM was appended to the ring buffer (level for the waveform).
    AudioCaptured { samples: usize, level: f32 },
    /// Esc / cancel binding pressed (§7 F6).
    Cancel,
    /// Streaming ASR produced a partial hypothesis (pass 1).
    AsrPartial {
        utterance: UtteranceId,
        text: String,
    },
    /// Refined ASR finished (pass 2, pre-cleanup).
    AsrFinal {
        utterance: UtteranceId,
        transcript: Transcript,
        location: ProcessingLocation,
    },
    /// ASR failed (or returned empty ⇒ `empty: true`, "didn't catch that" §29).
    AsrFailed {
        utterance: UtteranceId,
        location: ProcessingLocation,
        empty: bool,
    },
    /// Cleanup finished. `guard_fallback` = hallucination guard rejected the model output
    /// and substituted lightly-cleaned verbatim (§17.2).
    CleanupDone {
        utterance: UtteranceId,
        text: String,
        location: ProcessingLocation,
        guard_fallback: bool,
    },
    /// Cleanup failed outright.
    CleanupFailed {
        utterance: UtteranceId,
        location: ProcessingLocation,
    },
    /// Cloud call timed out / errored mid-utterance → orchestrator must fall back local (§19).
    CloudUnavailable,
    /// Insertion engine reported an outcome.
    InsertionCompleted {
        utterance: UtteranceId,
        outcome: InsertionOutcome,
    },
    /// Insertion failed all strategies above ClipboardNotify.
    InsertionFailed { utterance: UtteranceId },
    /// User interfered mid-flight (focus change / caret move / edit in pending range, §12.3).
    UserInterference { utterance: UtteranceId },
    /// The focused app is disabled by a per-app rule.
    AppDisabled,
    /// The focused app became enabled again.
    AppEnabled,
}

/// Effects emitted BY the orchestrator for the interpreter (shell / pipeline) to execute.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Effect {
    /// Start audio capture into the ring buffer immediately (§28: ≤50 ms perceived start).
    StartCapture { utterance: UtteranceId },
    /// Stop capture and finalize the audio window.
    StopCapture,
    /// Discard buffered audio + partials (cancel path).
    DiscardCapture,
    /// Play an earcon (§12.6).
    PlaySound { sound: Sound },
    /// Show/update the overlay HUD.
    ShowOverlay {
        state: State,
        location_chip: Option<ProcessingLocation>,
    },
    /// Update live waveform level.
    UpdateWaveform { level: f32 },
    /// Show live partial text in the overlay (pass 1, §12.3 strategy A).
    ShowPartial { text: String },
    /// Run refined ASR on the finalized audio window.
    RunAsr {
        utterance: UtteranceId,
        prefer: ProcessingLocation,
    },
    /// Run cleanup on the refined transcript.
    RunCleanup {
        utterance: UtteranceId,
        transcript: String,
        verbatim: bool,
        prefer: ProcessingLocation,
    },
    /// Insert final text via the cascade.
    RunInsertion {
        utterance: UtteranceId,
        text: String,
    },
    /// Copy text to clipboard + toast — the words are never lost (§29).
    NotifyTextOnClipboard { text: String },
    /// Persist the utterance record to local history (§24) and arm undo (§26).
    PersistUtterance {
        utterance: UtteranceId,
        location: ProcessingLocation,
        inserted: bool,
        /// The refined ASR text *before* cleanup, when we got that far. The shell only ever
        /// sees the post-cleanup string it inserted, so without this the dashboard cannot
        /// show what the model actually heard (§24 transcript_final).
        #[serde(skip_serializing_if = "Option::is_none")]
        transcript_final: Option<String>,
    },
    /// Arm the single-keystroke undo for the exact inserted range (§7 F21).
    ArmUndo { utterance: UtteranceId },
    /// Fade the overlay back to idle after the Done confirmation (§12.2: 400–700 ms).
    ScheduleFadeToIdle,
}

/// Earcons (§12.6).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Sound {
    CaptureStart,
    CaptureCancel,
    InsertionDone,
    DidntCatchThat,
    Error,
}

/// Per-utterance privacy accounting record (§20, §7 F25): the source of the lock/cloud chip.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PrivacyRecord {
    pub utterance: UtteranceId,
    /// Did any audio or text leave the device for this utterance?
    pub data_left_device: bool,
    pub asr_location: Option<ProcessingLocation>,
    pub cleanup_location: Option<ProcessingLocation>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn events_and_effects_roundtrip_json() {
        let e = Event::AsrFinal {
            utterance: UtteranceId("u1".into()),
            transcript: Transcript {
                instant: Some("helo".into()),
                refined: "hello".into(),
                language: Some("en".into()),
            },
            location: ProcessingLocation::Local,
        };
        let j = serde_json::to_string(&e).unwrap();
        assert_eq!(serde_json::from_str::<Event>(&j).unwrap(), e);

        let f = Effect::RunCleanup {
            utterance: UtteranceId("u1".into()),
            transcript: "hello".into(),
            verbatim: false,
            prefer: ProcessingLocation::Local,
        };
        let j = serde_json::to_string(&f).unwrap();
        assert_eq!(serde_json::from_str::<Effect>(&j).unwrap(), f);
    }

    #[test]
    fn persist_utterance_carries_the_pre_cleanup_transcript_at_top_level() {
        // The shell reads this effect as a flat dictionary and hands it straight to the store,
        // so the key has to sit alongside `inserted` — and vanish when there is nothing to say.
        let f = Effect::PersistUtterance {
            utterance: UtteranceId("u1".into()),
            location: ProcessingLocation::Local,
            inserted: true,
            transcript_final: Some("hello world".into()),
        };
        let v: serde_json::Value = serde_json::to_value(&f).unwrap();
        assert_eq!(v["type"], "persist_utterance");
        assert_eq!(v["transcript_final"], "hello world");
        assert_eq!(serde_json::from_str::<Effect>(&v.to_string()).unwrap(), f);

        let bare = Effect::PersistUtterance {
            utterance: UtteranceId("u2".into()),
            location: ProcessingLocation::Local,
            inserted: false,
            transcript_final: None,
        };
        let v: serde_json::Value = serde_json::to_value(&bare).unwrap();
        assert!(v.get("transcript_final").is_none(), "null must be omitted");
    }

    #[test]
    fn strategy_cascade_order_is_stable() {
        assert!(InsertionStrategy::Direct < InsertionStrategy::Tsf);
        assert!(InsertionStrategy::Tsf < InsertionStrategy::PasteRestore);
        assert!(InsertionStrategy::PasteRestore < InsertionStrategy::ClipboardNotify);
    }
}
