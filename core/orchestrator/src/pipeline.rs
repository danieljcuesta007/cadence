//! Headless pipeline runner: interprets orchestrator [`Effect`]s against real engine traits.
//! This is what the native shells will do via FFI (§23); here it powers the Phase-0 exit
//! criterion (WAV → cleaned text) and end-to-end core tests — no UI, no threads.

use std::collections::VecDeque;
use std::time::Instant;

use cadence_asr::{pcm_i16_to_f32, AsrEngine, AsrError};
use cadence_cleanup::CleanupEngine;
use cadence_ipc::{
    Effect, Event, InsertionOutcome, InsertionStrategy, Mode, PrivacyRecord, ProcessingLocation,
    ProcessingPolicy, State,
};

use crate::machine::Orchestrator;
use crate::partial::PartialScheduler;
use crate::ring::RingBuffer;

/// Where the final text lands. The real shells implement the §7 F20 cascade; tests and the
/// headless CLI use [`CollectSink`].
pub trait InsertionSink {
    fn insert(&mut self, text: &str) -> InsertionOutcome;
}

/// Pretends to be a perfectly-behaved target app.
#[derive(Default)]
pub struct CollectSink {
    pub inserted: Vec<String>,
}

impl InsertionSink for CollectSink {
    fn insert(&mut self, text: &str) -> InsertionOutcome {
        self.inserted.push(text.to_string());
        InsertionOutcome {
            strategy: InsertionStrategy::Direct,
            inserted: true,
            clipboard_restored: true,
        }
    }
}

#[derive(Debug, Default, Clone)]
pub struct Timings {
    pub asr_ms: u128,
    pub cleanup_ms: u128,
    pub insertion_ms: u128,
    pub total_ms: u128,
}

#[derive(Debug)]
pub struct RunReport {
    pub refined_transcript: Option<String>,
    pub final_text: Option<String>,
    pub inserted: bool,
    pub privacy: Option<PrivacyRecord>,
    pub timings: Timings,
    pub audio_samples: usize,
    pub dropped_samples: u64,
    /// Instant-pass partials shown while the user was still speaking (§12.3), in order.
    pub partials: Vec<String>,
}

pub struct Pipeline<'a> {
    pub machine: Orchestrator,
    pub ring: RingBuffer,
    pub asr: &'a mut dyn AsrEngine,
    pub cleanup: &'a dyn CleanupEngine,
    pub sink: &'a mut dyn InsertionSink,
}

impl<'a> Pipeline<'a> {
    pub fn new(
        ring_capacity: usize,
        asr: &'a mut dyn AsrEngine,
        cleanup: &'a dyn CleanupEngine,
        sink: &'a mut dyn InsertionSink,
    ) -> Self {
        Self {
            machine: Orchestrator::new(),
            ring: RingBuffer::new(ring_capacity),
            asr,
            cleanup,
            sink,
        }
    }

    /// Run one full PTT utterance over a PCM window (16 kHz mono i16).
    pub fn run_utterance(
        &mut self,
        pcm: &[i16],
        mode: Mode,
        policy: ProcessingPolicy,
    ) -> RunReport {
        let start = Instant::now();
        let mut report = RunReport {
            refined_transcript: None,
            final_text: None,
            inserted: false,
            privacy: None,
            timings: Timings::default(),
            audio_samples: pcm.len(),
            dropped_samples: 0,
            partials: Vec::new(),
        };

        // Fresh instant-pass stream for this utterance (the engine may be reused across runs).
        self.asr.reset_stream();
        let mut scheduler = PartialScheduler::default();
        let mut listening_utt = None;

        let mut queue: VecDeque<Event> = VecDeque::new();
        queue.push_back(Event::TriggerDown { mode, policy });

        // Feed audio in ~100 ms chunks like a capture callback would.
        for chunk in pcm.chunks(1600) {
            queue.push_back(Event::AudioCaptured {
                samples: chunk.len(),
                level: 0.5,
            });
        }
        queue.push_back(Event::TriggerUp);

        let mut audio_fed = 0usize;
        while let Some(event) = queue.pop_front() {
            // Mirror what the capture side does: samples land in the ring buffer as the
            // AudioCaptured events flow.
            let audio_samples = if let Event::AudioCaptured { samples, .. } = &event {
                let end = (audio_fed + samples).min(pcm.len());
                self.ring.push(&pcm[audio_fed..end]);
                audio_fed = end;
                Some(*samples)
            } else {
                None
            };
            let effects = self.machine.handle(event);
            for effect in effects {
                if let Effect::StartCapture { utterance } = &effect {
                    listening_utt = Some(utterance.clone());
                    scheduler.reset();
                }
                self.execute(effect, &mut queue, &mut report);
            }

            // Instant pass (§12.3): on cadence, decode the growing window and feed a partial
            // back into the machine, which surfaces it as ShowPartial. Synchronous here, so the
            // partial "completes" the moment it returns.
            if let (Some(samples), Some(utt)) = (audio_samples, listening_utt.clone()) {
                if self.machine.state() == State::Listening && scheduler.on_audio(samples) {
                    let window = self.ring.snapshot();
                    // Sliding tail (§12.3): long dictations decode only the recent window.
                    let window = &window[scheduler.window_start(window.len())..];
                    if let Ok(t) = self.asr.transcribe_partial(&pcm_i16_to_f32(window)) {
                        if let Some(text) = t.instant {
                            // Synchronous here: feed the partial through the machine now, while
                            // still Listening, so its ShowPartial isn't stranded behind the
                            // queued TriggerUp (after which the machine drops late partials).
                            let fx = self.machine.handle(Event::AsrPartial {
                                utterance: utt,
                                text,
                            });
                            for effect in fx {
                                self.execute(effect, &mut queue, &mut report);
                            }
                        }
                    }
                    scheduler.on_complete();
                }
            }
        }

        report.privacy = self.machine.last_privacy().cloned();
        report.timings.total_ms = start.elapsed().as_millis();
        report
    }

    fn execute(&mut self, effect: Effect, queue: &mut VecDeque<Event>, report: &mut RunReport) {
        match effect {
            Effect::StopCapture => {
                // finalize window: drained on RunAsr below
            }
            Effect::DiscardCapture => {
                self.ring.clear();
            }
            Effect::RunAsr { utterance, .. } => {
                report.dropped_samples = self.ring.dropped();
                let window = self.ring.drain();
                let t = Instant::now();
                let result = self.asr.transcribe(&pcm_i16_to_f32(&window));
                report.timings.asr_ms = t.elapsed().as_millis();
                match result {
                    Ok(transcript) => {
                        report.refined_transcript = Some(transcript.refined.clone());
                        queue.push_back(Event::AsrFinal {
                            utterance,
                            transcript,
                            location: ProcessingLocation::Local,
                        });
                    }
                    Err(AsrError::Empty) => queue.push_back(Event::AsrFailed {
                        utterance,
                        location: ProcessingLocation::Local,
                        empty: true,
                    }),
                    Err(_) => queue.push_back(Event::AsrFailed {
                        utterance,
                        location: ProcessingLocation::Local,
                        empty: false,
                    }),
                }
            }
            Effect::RunCleanup {
                utterance,
                transcript,
                verbatim,
                ..
            } => {
                let t = Instant::now();
                let result = self.cleanup.cleanup(&transcript, verbatim);
                report.timings.cleanup_ms = t.elapsed().as_millis();
                match result {
                    Ok(out) => queue.push_back(Event::CleanupDone {
                        utterance,
                        text: out.text,
                        location: ProcessingLocation::Local,
                        guard_fallback: out.guard_fallback,
                    }),
                    Err(_) => queue.push_back(Event::CleanupFailed {
                        utterance,
                        location: ProcessingLocation::Local,
                    }),
                }
            }
            Effect::RunInsertion { utterance, text } => {
                report.final_text = Some(text.clone());
                let t = Instant::now();
                let outcome = self.sink.insert(&text);
                report.timings.insertion_ms = t.elapsed().as_millis();
                report.inserted = outcome.inserted;
                queue.push_back(Event::InsertionCompleted { utterance, outcome });
            }
            // Instant-pass partial: headlessly, record it so tests can assert the two-pass
            // sequence (the shells render it in the overlay).
            Effect::ShowPartial { text } => report.partials.push(text),
            // Presentation-only effects: no-ops headlessly.
            Effect::StartCapture { .. }
            | Effect::PlaySound { .. }
            | Effect::ShowOverlay { .. }
            | Effect::UpdateWaveform { .. }
            | Effect::NotifyTextOnClipboard { .. }
            | Effect::PersistUtterance { .. }
            | Effect::ArmUndo { .. }
            | Effect::ScheduleFadeToIdle => {}
        }
    }
}
