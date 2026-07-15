//! cadence-asr — local ASR runtime bindings (§17.1).
//!
//! Phase 0: [`AsrEngine`] trait + a deterministic mock (for headless orchestrator tests) and a
//! whisper.cpp-backed engine behind the `whisper` feature (ADR-0003). The streaming
//! instant-pass API lands in Phase 1; Phase 0 covers the refined pass (WAV window → text).

use cadence_ipc::Transcript;
use thiserror::Error;

#[derive(Debug, Error)]
pub enum AsrError {
    #[error("no speech detected")]
    Empty,
    #[error("asr engine failed: {0}")]
    Engine(String),
}

pub trait AsrEngine {
    /// Refined (final) pass over a complete utterance window. 16 kHz mono f32 PCM in [-1, 1].
    fn transcribe(&mut self, pcm: &[f32]) -> Result<Transcript, AsrError>;

    /// Instant pass (§12.3 strategy B): a fast, low-latency decode over the audio captured
    /// *so far* — called repeatedly on a growing window while the user is still speaking, to
    /// surface a live partial. Returns a [`Transcript`] whose `instant` carries the partial
    /// text; `refined` mirrors it for callers that ignore the split. Accuracy is traded for
    /// latency, so the refined [`transcribe`](AsrEngine::transcribe) pass is still authoritative.
    ///
    /// Default impl delegates to `transcribe` and relabels the output as instant, so engines
    /// without a dedicated fast path stay correct (just not fast).
    fn transcribe_partial(&mut self, pcm: &[f32]) -> Result<Transcript, AsrError> {
        let t = self.transcribe(pcm)?;
        Ok(Transcript {
            instant: Some(t.refined.clone()),
            refined: t.refined,
            language: t.language,
        })
    }

    /// Drop any per-utterance streaming state carried across [`transcribe_partial`] calls, so
    /// the next utterance's instant pass starts clean. Default no-op for stateless engines.
    fn reset_stream(&mut self) {}
}

/// Deterministic mock for tests and for machines without a model present.
pub struct MockAsr {
    pub refined: String,
}

impl AsrEngine for MockAsr {
    fn transcribe(&mut self, pcm: &[f32]) -> Result<Transcript, AsrError> {
        if pcm.is_empty() {
            return Err(AsrError::Empty);
        }
        Ok(Transcript {
            instant: None,
            refined: self.refined.clone(),
            language: Some("en".into()),
        })
    }
}

/// Convert interleaved i16 PCM to the f32 format the engines expect.
pub fn pcm_i16_to_f32(samples: &[i16]) -> Vec<f32> {
    samples.iter().map(|&s| s as f32 / 32768.0).collect()
}

#[cfg(feature = "whisper")]
pub mod whisper {
    use super::{AsrEngine, AsrError};
    use cadence_ipc::Transcript;
    use whisper_rs::{
        FullParams, SamplingStrategy, WhisperContext, WhisperContextParameters, WhisperState,
    };

    pub struct WhisperAsr {
        ctx: WhisperContext,
        threads: i32,
        /// Reusable decode state for the instant pass, created lazily and kept alive across a
        /// stream so we pay `whisper_init_state` (KV-cache alloc) once per utterance, not per
        /// partial. Cleared at utterance boundaries via [`reset_stream`](WhisperAsr::reset_stream).
        partial_state: Option<WhisperState>,
        /// Encoder context length for the instant pass (§12.3). 0 = model default (1500 frames
        /// for base = 30 s). Shrinking it caps the encoder cost on short windows — the same knob
        /// whisper.cpp's `stream` example exposes as `--audio-ctx`. Must stay ≥ the window's own
        /// frame count (~50 frames/s) or trailing audio is truncated.
        partial_audio_ctx: i32,
    }

    impl WhisperAsr {
        pub fn load(model_path: &str) -> Result<Self, AsrError> {
            let ctx =
                WhisperContext::new_with_params(model_path, WhisperContextParameters::default())
                    .map_err(|e| AsrError::Engine(format!("model load: {e}")))?;
            let threads = std::thread::available_parallelism()
                .map(|n| (n.get() as i32).min(8))
                .unwrap_or(4);
            Ok(Self {
                ctx,
                threads,
                partial_state: None,
                partial_audio_ctx: 0,
            })
        }

        /// Cap the instant-pass encoder length (frames; ~50 per second of audio). 0 restores the
        /// model default. Callers should size this to their rolling-window cap.
        pub fn set_partial_audio_ctx(&mut self, frames: i32) {
            self.partial_audio_ctx = frames;
        }
    }

    /// Low-latency instant-pass params. Free function (not a method) so it borrows nothing from
    /// `WhisperAsr` — otherwise the returned [`FullParams`] would pin an immutable borrow of
    /// `self` that collides with the `&mut partial_state` the decode needs.
    fn fast_params<'a>(threads: i32, audio_ctx: i32) -> FullParams<'a, 'a> {
        let mut params = FullParams::new(SamplingStrategy::Greedy { best_of: 1 });
        params.set_n_threads(threads);
        params.set_language(Some("en"));
        params.set_print_special(false);
        params.set_print_progress(false);
        params.set_print_realtime(false);
        params.set_print_timestamps(false);
        params.set_suppress_blank(true);
        // Instant-pass shortcuts: one segment, no cross-window prompt, capped encoder.
        params.set_single_segment(true);
        params.set_no_context(true);
        if audio_ctx > 0 {
            params.set_audio_ctx(audio_ctx);
        }
        params
    }

    impl AsrEngine for WhisperAsr {
        fn transcribe(&mut self, pcm: &[f32]) -> Result<Transcript, AsrError> {
            if pcm.is_empty() {
                return Err(AsrError::Empty);
            }
            let mut state = self
                .ctx
                .create_state()
                .map_err(|e| AsrError::Engine(format!("state: {e}")))?;
            let mut params = FullParams::new(SamplingStrategy::Greedy { best_of: 1 });
            params.set_n_threads(self.threads);
            params.set_language(Some("en"));
            params.set_print_special(false);
            params.set_print_progress(false);
            params.set_print_realtime(false);
            params.set_print_timestamps(false);
            params.set_suppress_blank(true);
            state
                .full(params, pcm)
                .map_err(|e| AsrError::Engine(format!("decode: {e}")))?;
            let refined = collect_text(&state);
            if refined.is_empty() {
                return Err(AsrError::Empty);
            }
            Ok(Transcript {
                instant: None,
                refined,
                language: Some("en".into()),
            })
        }

        fn transcribe_partial(&mut self, pcm: &[f32]) -> Result<Transcript, AsrError> {
            if pcm.is_empty() {
                return Err(AsrError::Empty);
            }
            if self.partial_state.is_none() {
                self.partial_state = Some(
                    self.ctx
                        .create_state()
                        .map_err(|e| AsrError::Engine(format!("partial state: {e}")))?,
                );
            }
            let params = fast_params(self.threads, self.partial_audio_ctx);
            let state = self.partial_state.as_mut().expect("state just ensured");
            state
                .full(params, pcm)
                .map_err(|e| AsrError::Engine(format!("partial decode: {e}")))?;
            let text = collect_text(state);
            if text.is_empty() {
                return Err(AsrError::Empty);
            }
            Ok(Transcript {
                instant: Some(text.clone()),
                refined: text,
                language: Some("en".into()),
            })
        }

        fn reset_stream(&mut self) {
            self.partial_state = None;
        }
    }

    fn collect_text(state: &WhisperState) -> String {
        let mut out = String::new();
        for segment in state.as_iter() {
            if let Ok(text) = segment.to_str() {
                out.push_str(text);
            }
        }
        out.trim().to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mock_returns_configured_text() {
        let mut m = MockAsr {
            refined: "hello world".into(),
        };
        assert_eq!(m.transcribe(&[0.1, 0.2]).unwrap().refined, "hello world");
    }

    #[test]
    fn mock_reports_empty_on_silence_window() {
        let mut m = MockAsr {
            refined: "x".into(),
        };
        assert!(matches!(m.transcribe(&[]), Err(AsrError::Empty)));
    }

    #[test]
    fn i16_conversion_is_normalized() {
        let f = pcm_i16_to_f32(&[0, i16::MAX, i16::MIN]);
        assert_eq!(f[0], 0.0);
        assert!((f[1] - 0.99997).abs() < 1e-4);
        assert_eq!(f[2], -1.0);
    }
}
