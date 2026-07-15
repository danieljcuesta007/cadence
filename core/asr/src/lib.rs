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
    use whisper_rs::{FullParams, SamplingStrategy, WhisperContext, WhisperContextParameters};

    pub struct WhisperAsr {
        ctx: WhisperContext,
        threads: i32,
    }

    impl WhisperAsr {
        pub fn load(model_path: &str) -> Result<Self, AsrError> {
            let ctx =
                WhisperContext::new_with_params(model_path, WhisperContextParameters::default())
                    .map_err(|e| AsrError::Engine(format!("model load: {e}")))?;
            let threads = std::thread::available_parallelism()
                .map(|n| (n.get() as i32).min(8))
                .unwrap_or(4);
            Ok(Self { ctx, threads })
        }
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
            let mut refined = String::new();
            for segment in state.as_iter() {
                if let Ok(text) = segment.to_str() {
                    refined.push_str(text);
                }
            }
            let refined = refined.trim().to_string();
            if refined.is_empty() {
                return Err(AsrError::Empty);
            }
            Ok(Transcript {
                instant: None,
                refined,
                language: Some("en".into()),
            })
        }
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
