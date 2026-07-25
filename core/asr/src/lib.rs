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

    /// Set the decode language: "auto" (detect per utterance, multilingual models only) or an
    /// ISO code like "en"/"es". Cheap — language is a per-decode parameter, not baked into the
    /// loaded model, so this takes effect on the next `transcribe`. Default no-op for engines
    /// (like the mock) that don't decode. Empty string is ignored by convention.
    fn set_language(&mut self, _lang: &str) {}

    /// Bias decoding toward a set of terms the user cares about (proper nouns, jargon, names)
    /// — whisper's `initial_prompt` mechanism (§ personal dictionary). The prompt is a plain
    /// phrase/list; empty clears it. Takes effect on the next refined `transcribe`. Default
    /// no-op for engines that don't decode.
    fn set_prompt(&mut self, _prompt: &str) {}
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
        /// Decode language passed to whisper. "auto" lets whisper detect the spoken language
        /// per utterance (multilingual models only) — this is what makes bilingual dictation
        /// "just work". An explicit ISO code ("en", "es") pins it. Resolved once from
        /// `CADENCE_LANG` at load; see [`resolve_language`].
        lang: String,
        /// Personal-dictionary bias (§): fed to whisper as `initial_prompt` on the refined pass
        /// so proper nouns / jargon the user added decode with the right spelling. Empty = no
        /// bias. Set by the shell from the stored vocabulary.
        prompt: String,
    }

    /// Encoder frames per second of audio: whisper's mel is 100 fps, and the encoder's first
    /// conv layer strides by 2.
    const ENCODER_FRAMES_PER_SEC: f32 = 50.0;
    /// Full encoder context — 30 s, what the model was trained at.
    const FULL_AUDIO_CTX: i32 = 1500;
    /// Headroom over the audio's own frame count. The encoder must see past the last frame of
    /// speech (trailing context is what lets it finish a word), and detection of a stray frame
    /// boundary should never clip the tail.
    const REFINED_CTX_MARGIN: i32 = 128;
    /// Never shrink below this. Sizing the window to the audio is *not* free: the model has only
    /// ever seen full-length positional embeddings, so a short window degrades accuracy even
    /// when it covers every frame of speech. Measured on the §30 fixtures (bundled small, 225
    /// ref words, 2026-07-25) — the cliff is steep and 1280 is the knee:
    ///
    /// | audio_ctx | WER | mean ASR |
    /// |---|---|---|
    /// | 1500 (full) | 1.778 % | 642 ms |
    /// | **1280** | **1.778 %** | **566 ms** |
    /// | 1024 | 2.222 % | 556 ms |
    /// | 768 | 3.556 % | 503 ms |
    /// | sized-to-audio (~384) | 4.000 % | 458 ms |
    ///
    /// Accuracy is the daily-use bottleneck, so we take only the free 12 % and stop.
    const MIN_REFINED_CTX: i32 = 1280;

    /// Encoder context for a refined decode of `samples` at 16 kHz.
    ///
    /// Whisper always encodes a 30 s mel, padding a 4 s utterance with 26 s of silence and paying
    /// full encoder cost for it. Trimming `audio_ctx` (the knob whisper.cpp's `stream` example
    /// exposes) reclaims some of that — but only down to [`MIN_REFINED_CTX`], below which
    /// accuracy falls off a cliff. Long utterances still grow the window to cover their own
    /// audio: truncating real speech is the one thing this must never do.
    ///
    /// `CADENCE_REFINED_CTX` overrides: a frame count pins it, `0` restores the full 30 s
    /// encoder (the pre-2026-07-25 behaviour) for A/B measurement.
    fn refined_audio_ctx(samples: usize) -> i32 {
        if let Some(v) = std::env::var("CADENCE_REFINED_CTX")
            .ok()
            .and_then(|s| s.trim().parse::<i32>().ok())
        {
            return v.clamp(0, FULL_AUDIO_CTX);
        }
        let secs = samples as f32 / 16_000.0;
        let needed = (secs * ENCODER_FRAMES_PER_SEC).ceil() as i32 + REFINED_CTX_MARGIN;
        needed.clamp(MIN_REFINED_CTX, FULL_AUDIO_CTX)
    }

    /// Language for the decode: `CADENCE_LANG` if set (e.g. "es" to force Spanish, "en" to
    /// force English), otherwise "auto" so whisper detects it from the audio. Auto-detection
    /// requires a multilingual model — the English-only `.en` tiers ignore it and stay English.
    fn resolve_language() -> String {
        std::env::var("CADENCE_LANG")
            .ok()
            .map(|s| s.trim().to_lowercase())
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| "auto".into())
    }

    impl WhisperAsr {
        pub fn load(model_path: &str) -> Result<Self, AsrError> {
            let mut cparams = WhisperContextParameters::default();
            // Flash attention: a fused attention kernel, mathematically the same result with a
            // smaller memory footprint — pure latency, no accuracy cost (verified against the
            // §30 harness, not assumed). Off by default in whisper-rs; we opt in.
            // `CADENCE_FLASH_ATTN=0` disables it for A/B measurement.
            cparams.flash_attn = std::env::var("CADENCE_FLASH_ATTN")
                .ok()
                .map(|v| v.trim() != "0")
                .unwrap_or(true);
            let ctx = WhisperContext::new_with_params(model_path, cparams)
                .map_err(|e| AsrError::Engine(format!("model load: {e}")))?;
            let threads = std::thread::available_parallelism()
                .map(|n| (n.get() as i32).min(8))
                .unwrap_or(4);
            Ok(Self {
                ctx,
                threads,
                partial_state: None,
                partial_audio_ctx: 0,
                lang: resolve_language(),
                prompt: String::new(),
            })
        }

        /// Cap the instant-pass encoder length (frames; ~50 per second of audio). 0 restores the
        /// model default. Callers should size this to their rolling-window cap.
        pub fn set_partial_audio_ctx(&mut self, frames: i32) {
            self.partial_audio_ctx = frames;
        }

        /// What to record as the utterance's language. A pinned code is reported as-is; "auto"
        /// leaves it unknown (whisper detected it internally, but we don't surface the id here).
        fn reported_language(&self) -> Option<String> {
            if self.lang == "auto" {
                None
            } else {
                Some(self.lang.clone())
            }
        }
    }

    /// Low-latency instant-pass params. Free function (not a method) so it borrows nothing from
    /// `WhisperAsr` — otherwise the returned [`FullParams`] would pin an immutable borrow of
    /// `self` that collides with the `&mut partial_state` the decode needs.
    fn fast_params<'a>(threads: i32, audio_ctx: i32, lang: &'a str) -> FullParams<'a, 'a> {
        let mut params = FullParams::new(SamplingStrategy::Greedy { best_of: 1 });
        params.set_n_threads(threads);
        params.set_language(Some(lang));
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
            params.set_language(Some(&self.lang));
            params.set_print_special(false);
            params.set_print_progress(false);
            params.set_print_realtime(false);
            params.set_print_timestamps(false);
            params.set_suppress_blank(true);
            // Personal-dictionary bias: proper nouns/jargon spell correctly (§). Refined pass
            // only — the instant pass stays lean, and the refined text is authoritative.
            if !self.prompt.is_empty() {
                params.set_initial_prompt(&self.prompt);
            }
            // Encode only as much context as the audio occupies (see `refined_audio_ctx`).
            let ctx_frames = refined_audio_ctx(pcm.len());
            if ctx_frames > 0 && ctx_frames < FULL_AUDIO_CTX {
                params.set_audio_ctx(ctx_frames);
            }
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
                language: self.reported_language(),
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
            let params = fast_params(self.threads, self.partial_audio_ctx, &self.lang);
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
                language: self.reported_language(),
            })
        }

        fn reset_stream(&mut self) {
            self.partial_state = None;
        }

        fn set_language(&mut self, lang: &str) {
            let lang = lang.trim();
            if !lang.is_empty() {
                self.lang = lang.to_lowercase();
            }
        }

        fn set_prompt(&mut self, prompt: &str) {
            self.prompt = prompt.trim().to_string();
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
