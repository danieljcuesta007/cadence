//! The orchestrator state machine (§12.2, §26): a pure Mealy machine. `handle(Event)` returns
//! the effects the interpreter (native shell or headless pipeline) must execute. No threads,
//! no clocks, no I/O — every transition, cancel path, fallback, and concurrency rule is
//! deterministically testable.
//!
//! Terminal presentation states (Done/Cancelled/Error) collapse to `Idle` inside the machine;
//! the overlay renders them from the emitted `ShowOverlay` effect and fades via
//! `ScheduleFadeToIdle`. This keeps §26's concurrency rule ("ignore new PTT until DONE")
//! encodable without timer events.

use cadence_ipc::{
    Effect, Event, InsertionStrategy, Mode, PrivacyRecord, ProcessingLocation, ProcessingPolicy,
    Sound, State, UtteranceId,
};

/// What the machine is currently waiting on (used to route cloud failures, §19/§29).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Pending {
    Asr(ProcessingLocation),
    Cleanup(ProcessingLocation),
    Insertion,
}

#[derive(Debug)]
struct Utterance {
    id: UtteranceId,
    mode: Mode,
    policy: ProcessingPolicy,
    /// Cloud became unavailable mid-utterance → all subsequent work prefers local.
    degraded: bool,
    pending: Option<Pending>,
    /// Refined (pre-cleanup) transcript, kept so cleanup failure can never lose words.
    refined: Option<String>,
    /// Language the ASR reported for this utterance (None = decoded on auto-detect).
    language: Option<String>,
    /// Final text handed to insertion, kept so insertion failure can never lose words.
    final_text: Option<String>,
    asr_location: Option<ProcessingLocation>,
    cleanup_location: Option<ProcessingLocation>,
}

pub struct Orchestrator {
    state: State,
    current: Option<Utterance>,
    next_id: u64,
    last_privacy: Option<PrivacyRecord>,
}

impl Default for Orchestrator {
    fn default() -> Self {
        Self::new()
    }
}

impl Orchestrator {
    pub fn new() -> Self {
        Self {
            state: State::Idle,
            current: None,
            next_id: 1,
            last_privacy: None,
        }
    }

    pub fn state(&self) -> State {
        self.state
    }

    /// Privacy accounting for the most recently finished utterance (§7 F25, AC-25).
    pub fn last_privacy(&self) -> Option<&PrivacyRecord> {
        self.last_privacy.as_ref()
    }

    fn mint_id(&mut self) -> UtteranceId {
        let id = UtteranceId(format!("utt-{}", self.next_id));
        self.next_id += 1;
        id
    }

    /// Preferred processing location per policy + degradation state (§19).
    fn prefer(policy: ProcessingPolicy, degraded: bool) -> ProcessingLocation {
        match policy {
            ProcessingPolicy::LocalOnly => ProcessingLocation::Local,
            _ if degraded => ProcessingLocation::Local,
            _ => ProcessingLocation::Cloud,
        }
    }

    /// Per-utterance truth for the chip (§19): cloud iff any stage actually ran in cloud.
    fn overall_location(u: &Utterance) -> ProcessingLocation {
        if u.asr_location == Some(ProcessingLocation::Cloud)
            || u.cleanup_location == Some(ProcessingLocation::Cloud)
        {
            ProcessingLocation::Cloud
        } else {
            ProcessingLocation::Local
        }
    }

    fn finish(&mut self, effects: &mut Vec<Effect>, overlay: State, inserted: bool) {
        let u = self
            .current
            .take()
            .expect("finish called with no active utterance");
        let location = Self::overall_location(&u);
        self.last_privacy = Some(PrivacyRecord {
            utterance: u.id.clone(),
            data_left_device: location == ProcessingLocation::Cloud,
            asr_location: u.asr_location,
            cleanup_location: u.cleanup_location,
        });
        effects.push(Effect::ShowOverlay {
            state: overlay,
            location_chip: Some(location),
        });
        effects.push(Effect::PersistUtterance {
            utterance: u.id,
            location,
            inserted,
            transcript_final: u.refined,
            language: u.language,
        });
        effects.push(Effect::ScheduleFadeToIdle);
        self.state = State::Idle;
    }

    fn cancel(&mut self, effects: &mut Vec<Effect>) {
        self.current = None;
        effects.push(Effect::DiscardCapture);
        effects.push(Effect::PlaySound {
            sound: Sound::CaptureCancel,
        });
        effects.push(Effect::ShowOverlay {
            state: State::Cancelled,
            location_chip: None,
        });
        effects.push(Effect::ScheduleFadeToIdle);
        self.state = State::Idle;
    }

    /// Does `id` belong to the active utterance? Engine callbacks for a cancelled/finished
    /// utterance are dropped — a stale cloud reply must never leak into a new dictation.
    fn is_current(&self, id: &UtteranceId) -> bool {
        self.current.as_ref().is_some_and(|u| &u.id == id)
    }

    pub fn handle(&mut self, event: Event) -> Vec<Effect> {
        let mut fx = Vec::new();
        match event {
            // ---- activation -------------------------------------------------------------
            Event::TriggerDown { mode, policy } => {
                // §26: single utterance at a time; ignore PTT while one is active.
                if self.state != State::Idle || self.current.is_some() {
                    return fx;
                }
                let id = self.mint_id();
                self.current = Some(Utterance {
                    id: id.clone(),
                    mode,
                    policy,
                    degraded: false,
                    pending: None,
                    refined: None,
                    language: None,
                    final_text: None,
                    asr_location: None,
                    cleanup_location: None,
                });
                self.state = State::Listening;
                // §28: capture + earcon + overlay within 50 ms of key-down.
                fx.push(Effect::StartCapture { utterance: id });
                fx.push(Effect::PlaySound {
                    sound: Sound::CaptureStart,
                });
                fx.push(Effect::ShowOverlay {
                    state: State::Listening,
                    location_chip: None,
                });
            }
            Event::AppDisabled => {
                if self.state == State::Idle {
                    self.state = State::Disabled;
                    fx.push(Effect::ShowOverlay {
                        state: State::Disabled,
                        location_chip: None,
                    });
                }
            }
            Event::AppEnabled => {
                if self.state == State::Disabled {
                    self.state = State::Idle;
                    fx.push(Effect::ShowOverlay {
                        state: State::Idle,
                        location_chip: None,
                    });
                }
            }

            // ---- listening --------------------------------------------------------------
            Event::AudioCaptured { level, .. } => {
                if self.state == State::Listening {
                    fx.push(Effect::UpdateWaveform { level });
                }
            }
            Event::AsrPartial { utterance, text } => {
                if self.state == State::Listening && self.is_current(&utterance) {
                    fx.push(Effect::ShowPartial { text });
                }
            }
            Event::TriggerUp => {
                if self.state != State::Listening {
                    return fx;
                }
                let u = self.current.as_mut().expect("listening without utterance");
                let prefer = Self::prefer(u.policy, u.degraded);
                u.pending = Some(Pending::Asr(prefer));
                let id = u.id.clone();
                self.state = State::Thinking;
                fx.push(Effect::StopCapture);
                fx.push(Effect::ShowOverlay {
                    state: State::Thinking,
                    location_chip: None,
                });
                fx.push(Effect::RunAsr {
                    utterance: id,
                    prefer,
                });
            }

            // ---- cancel (§7 F6): valid while listening/thinking; too late once inserting.
            Event::Cancel => {
                if matches!(self.state, State::Listening | State::Thinking) {
                    self.cancel(&mut fx);
                }
            }

            // ---- degradation (§19, §29) -------------------------------------------------
            Event::CloudUnavailable => {
                if let Some(u) = self.current.as_mut() {
                    u.degraded = true;
                    let id = u.id.clone();
                    // If we were waiting on a cloud stage, immediately re-run it locally.
                    match u.pending {
                        Some(Pending::Asr(ProcessingLocation::Cloud)) => {
                            u.pending = Some(Pending::Asr(ProcessingLocation::Local));
                            fx.push(Effect::RunAsr {
                                utterance: id,
                                prefer: ProcessingLocation::Local,
                            });
                        }
                        Some(Pending::Cleanup(ProcessingLocation::Cloud)) => {
                            let transcript = u
                                .refined
                                .clone()
                                .expect("cleanup pending without transcript");
                            let verbatim = u.mode == Mode::Verbatim;
                            u.pending = Some(Pending::Cleanup(ProcessingLocation::Local));
                            fx.push(Effect::RunCleanup {
                                utterance: id,
                                transcript,
                                verbatim,
                                prefer: ProcessingLocation::Local,
                            });
                        }
                        _ => {}
                    }
                    // Indicator flips to offline/local — calm, not an error (§10.5).
                    fx.push(Effect::ShowOverlay {
                        state: self.state,
                        location_chip: Some(ProcessingLocation::Local),
                    });
                }
            }

            // ---- ASR results ------------------------------------------------------------
            Event::AsrFinal {
                utterance,
                transcript,
                location,
            } => {
                if self.state != State::Thinking || !self.is_current(&utterance) {
                    return fx;
                }
                let u = self.current.as_mut().unwrap();
                u.asr_location = Some(location);
                u.refined = Some(transcript.refined.clone());
                let verbatim = u.mode == Mode::Verbatim;
                let prefer = Self::prefer(u.policy, u.degraded);
                u.pending = Some(Pending::Cleanup(prefer));
                fx.push(Effect::RunCleanup {
                    utterance,
                    transcript: transcript.refined,
                    verbatim,
                    prefer,
                });
            }
            Event::AsrFailed {
                utterance,
                location,
                empty,
            } => {
                if self.state != State::Thinking || !self.is_current(&utterance) {
                    return fx;
                }
                if empty {
                    // Silence: no insertion, gentle feedback (§29).
                    self.current = None;
                    self.state = State::Idle;
                    fx.push(Effect::PlaySound {
                        sound: Sound::DidntCatchThat,
                    });
                    fx.push(Effect::ShowOverlay {
                        state: State::Idle,
                        location_chip: None,
                    });
                    return fx;
                }
                if location == ProcessingLocation::Cloud {
                    // Cloud ASR failed → local fallback for this utterance (AC-24).
                    let u = self.current.as_mut().unwrap();
                    u.degraded = true;
                    u.pending = Some(Pending::Asr(ProcessingLocation::Local));
                    fx.push(Effect::RunAsr {
                        utterance,
                        prefer: ProcessingLocation::Local,
                    });
                } else {
                    // Local ASR failed: unrecoverable for this utterance. No text exists yet,
                    // so there is nothing to preserve — honest error, back to idle (§29).
                    self.current = None;
                    self.state = State::Idle;
                    fx.push(Effect::PlaySound {
                        sound: Sound::Error,
                    });
                    fx.push(Effect::ShowOverlay {
                        state: State::Error,
                        location_chip: None,
                    });
                    fx.push(Effect::ScheduleFadeToIdle);
                }
            }

            // ---- cleanup results ---------------------------------------------------------
            Event::CleanupDone {
                utterance,
                text,
                location,
                ..
            } => {
                if self.state != State::Thinking || !self.is_current(&utterance) {
                    return fx;
                }
                let u = self.current.as_mut().unwrap();
                u.cleanup_location = Some(location);
                u.final_text = Some(text.clone());
                u.pending = Some(Pending::Insertion);
                let chip = Self::overall_location(u);
                self.state = State::Inserting;
                fx.push(Effect::ShowOverlay {
                    state: State::Inserting,
                    location_chip: Some(chip),
                });
                fx.push(Effect::RunInsertion { utterance, text });
            }
            Event::CleanupFailed {
                utterance,
                location,
            } => {
                if self.state != State::Thinking || !self.is_current(&utterance) {
                    return fx;
                }
                let u = self.current.as_mut().unwrap();
                if location == ProcessingLocation::Cloud {
                    let transcript = u.refined.clone().expect("cleanup without transcript");
                    let verbatim = u.mode == Mode::Verbatim;
                    u.degraded = true;
                    u.pending = Some(Pending::Cleanup(ProcessingLocation::Local));
                    fx.push(Effect::RunCleanup {
                        utterance,
                        transcript,
                        verbatim,
                        prefer: ProcessingLocation::Local,
                    });
                } else {
                    // Local cleanup failed → insert the raw refined transcript. Cleanup
                    // failure must never cost the user their words (P6, §29).
                    let text = u.refined.clone().expect("cleanup without transcript");
                    u.final_text = Some(text.clone());
                    u.pending = Some(Pending::Insertion);
                    let chip = Self::overall_location(u);
                    self.state = State::Inserting;
                    fx.push(Effect::ShowOverlay {
                        state: State::Inserting,
                        location_chip: Some(chip),
                    });
                    fx.push(Effect::RunInsertion { utterance, text });
                }
            }

            // ---- insertion results -------------------------------------------------------
            Event::InsertionCompleted { utterance, outcome } => {
                if self.state != State::Inserting || !self.is_current(&utterance) {
                    return fx;
                }
                if outcome.inserted {
                    fx.push(Effect::PlaySound {
                        sound: Sound::InsertionDone,
                    });
                    fx.push(Effect::ArmUndo { utterance });
                    self.finish(&mut fx, State::Done, true);
                } else {
                    // Words landed on the clipboard, not at the caret (§29 fallback).
                    debug_assert_eq!(outcome.strategy, InsertionStrategy::ClipboardNotify);
                    let text = self
                        .current
                        .as_ref()
                        .and_then(|u| u.final_text.clone())
                        .unwrap_or_default();
                    fx.push(Effect::NotifyTextOnClipboard { text });
                    self.finish(&mut fx, State::Done, false);
                }
            }
            Event::InsertionFailed { utterance } => {
                if self.state != State::Inserting || !self.is_current(&utterance) {
                    return fx;
                }
                // All strategies failed: the words go to the clipboard + notify. Never lost.
                let text = self
                    .current
                    .as_ref()
                    .and_then(|u| u.final_text.clone())
                    .unwrap_or_default();
                fx.push(Effect::NotifyTextOnClipboard { text });
                self.finish(&mut fx, State::Error, false);
            }
            Event::UserInterference { utterance } => {
                if self.state != State::Inserting || !self.is_current(&utterance) {
                    return fx;
                }
                // §12.3: never corrupt the user's document. Abort, words to clipboard.
                let text = self
                    .current
                    .as_ref()
                    .and_then(|u| u.final_text.clone())
                    .unwrap_or_default();
                fx.push(Effect::NotifyTextOnClipboard { text });
                self.finish(&mut fx, State::Done, false);
            }
        }
        fx
    }
}
