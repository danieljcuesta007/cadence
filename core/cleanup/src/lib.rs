//! cadence-cleanup — transcript → polished text (§17.2).
//!
//! Phase 0 ships a deterministic rule engine (ADR-0002); the small local LLM slots in behind
//! the same [`CleanupEngine`] trait in Phase 1. The §17.2 hallucination guard wraps ANY engine:
//! cleanup must never invent or lose meaning — if the output drifts, fall back to
//! lightly-cleaned verbatim.

use thiserror::Error;

#[derive(Debug, Error)]
pub enum CleanupError {
    #[error("cleanup engine failed: {0}")]
    Engine(String),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CleanupOutput {
    pub text: String,
    /// True iff the hallucination guard rejected the engine output and substituted
    /// lightly-cleaned verbatim.
    pub guard_fallback: bool,
}

pub trait CleanupEngine {
    /// `verbatim`: §7 F15 — no semantic change, no filler removal; literal transcript.
    fn cleanup(&self, transcript: &str, verbatim: bool) -> Result<CleanupOutput, CleanupError>;
}

// ---------------------------------------------------------------------------------------------
// Rule-based Phase-0 engine

/// Default filler tokens stripped in dictation mode (single-token; configurable).
const FILLERS: &[&str] = &["um", "uh", "uhh", "erm", "er", "hmm", "mmm", "mm"];

pub struct RuleCleanup {
    fillers: Vec<String>,
}

impl Default for RuleCleanup {
    fn default() -> Self {
        Self {
            fillers: FILLERS.iter().map(|s| s.to_string()).collect(),
        }
    }
}

impl RuleCleanup {
    pub fn with_fillers(fillers: Vec<String>) -> Self {
        Self { fillers }
    }

    fn is_filler(&self, word: &str) -> bool {
        let bare: String = word
            .chars()
            .filter(|c| c.is_alphanumeric())
            .collect::<String>()
            .to_lowercase();
        self.fillers.iter().any(|f| f == &bare)
    }
}

impl CleanupEngine for RuleCleanup {
    fn cleanup(&self, transcript: &str, verbatim: bool) -> Result<CleanupOutput, CleanupError> {
        if verbatim {
            // Literal mode: whitespace-normalize only; words untouched (AC-15).
            return Ok(CleanupOutput {
                text: normalize_ws(transcript),
                guard_fallback: false,
            });
        }
        let mut words: Vec<&str> = transcript.split_whitespace().collect();
        words.retain(|w| !self.is_filler(w));
        let joined = words.join(" ");
        let text = finish_sentences(&joined);
        Ok(CleanupOutput {
            text,
            guard_fallback: false,
        })
    }
}

/// Whitespace normalization only — the "lightly cleaned verbatim" guard fallback (§17.2).
pub fn normalize_ws(s: &str) -> String {
    s.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// Capitalize sentence starts, standalone "i", tidy space-before-punctuation, ensure terminal
/// punctuation.
fn finish_sentences(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 1);
    let mut cap_next = true;
    let mut chars = s.chars().peekable();
    while let Some(c) = chars.next() {
        if c == ' ' && matches!(chars.peek(), Some('.' | ',' | '!' | '?' | ';' | ':')) {
            continue; // drop space before punctuation
        }
        if cap_next && c.is_alphabetic() {
            out.extend(c.to_uppercase());
            cap_next = false;
        } else {
            out.push(c);
        }
        if matches!(c, '.' | '!' | '?') {
            cap_next = true;
        }
    }
    let mut text = fix_standalone_i(&out);
    if let Some(last) = text.chars().last() {
        if !matches!(last, '.' | '!' | '?' | '…' | ':') {
            text.push('.');
        }
    }
    text
}

fn fix_standalone_i(s: &str) -> String {
    s.split(' ')
        .map(|w| match w {
            "i" => "I".to_string(),
            "i'm" => "I'm".to_string(),
            "i'll" => "I'll".to_string(),
            "i've" => "I've".to_string(),
            "i'd" => "I'd".to_string(),
            _ => w.to_string(),
        })
        .collect::<Vec<_>>()
        .join(" ")
}

// ---------------------------------------------------------------------------------------------
// Hallucination guard (§17.2, §29)

/// Wraps any engine; enforces "cleanup must not invent facts / lose meaning".
pub struct Guarded<E: CleanupEngine> {
    inner: E,
    /// Minimum fraction of input content words that must survive into the output.
    pub min_retention: f64,
    /// Output/input length-ratio bounds (chars, after whitespace normalization).
    pub len_ratio: (f64, f64),
}

impl<E: CleanupEngine> Guarded<E> {
    pub fn new(inner: E) -> Self {
        Self {
            inner,
            min_retention: 0.6,
            len_ratio: (0.4, 2.0),
        }
    }
}

fn content_words(s: &str) -> Vec<String> {
    s.split_whitespace()
        .map(|w| {
            w.chars()
                .filter(|c| c.is_alphanumeric())
                .collect::<String>()
                .to_lowercase()
        })
        .filter(|w| !w.is_empty() && !FILLERS.contains(&w.as_str()))
        .collect()
}

impl<E: CleanupEngine> CleanupEngine for Guarded<E> {
    fn cleanup(&self, transcript: &str, verbatim: bool) -> Result<CleanupOutput, CleanupError> {
        let out = self.inner.cleanup(transcript, verbatim)?;
        if verbatim {
            // Verbatim forbids ANY word change: guard rejects everything but ws-normalization.
            let same = normalize_ws(transcript) == normalize_ws(&out.text);
            return Ok(if same {
                out
            } else {
                CleanupOutput {
                    text: normalize_ws(transcript),
                    guard_fallback: true,
                }
            });
        }
        let input_words = content_words(transcript);
        if input_words.is_empty() {
            return Ok(out);
        }
        let output_set: std::collections::HashSet<String> =
            content_words(&out.text).into_iter().collect();
        let retained = input_words
            .iter()
            .filter(|w| output_set.contains(*w))
            .count() as f64;
        let retention = retained / input_words.len() as f64;
        let in_len = normalize_ws(transcript).chars().count().max(1) as f64;
        let out_len = normalize_ws(&out.text).chars().count() as f64;
        let ratio = out_len / in_len;
        if retention < self.min_retention || ratio < self.len_ratio.0 || ratio > self.len_ratio.1 {
            Ok(CleanupOutput {
                text: finish_sentences(&normalize_ws(transcript)),
                guard_fallback: true,
            })
        } else {
            Ok(out)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn clean(s: &str) -> String {
        RuleCleanup::default().cleanup(s, false).unwrap().text
    }

    #[test]
    fn removes_fillers_and_finishes_sentence() {
        assert_eq!(
            clean("um so i think uh we should ship it"),
            "So I think we should ship it."
        );
    }

    #[test]
    fn capitalizes_after_terminal_punctuation() {
        assert_eq!(
            clean("hello there. how are you"),
            "Hello there. How are you."
        );
    }

    #[test]
    fn keeps_existing_terminal_punctuation() {
        assert_eq!(clean("ready to go!"), "Ready to go!");
    }

    #[test]
    fn tidies_space_before_punctuation() {
        assert_eq!(clean("wait , what ?"), "Wait, what?");
    }

    #[test]
    fn verbatim_mode_is_literal() {
        let out = RuleCleanup::default()
            .cleanup("um i  said   this", true)
            .unwrap();
        assert_eq!(out.text, "um i said this"); // fillers preserved, ws normalized
    }

    #[test]
    fn filler_words_inside_words_survive() {
        // "umbrella" contains "um" but is not a filler.
        assert_eq!(clean("bring the umbrella"), "Bring the umbrella.");
    }

    // ---- guard ----

    struct Inventor;
    impl CleanupEngine for Inventor {
        fn cleanup(&self, _t: &str, _v: bool) -> Result<CleanupOutput, CleanupError> {
            Ok(CleanupOutput {
                text: "I hereby resign effective immediately.".into(),
                guard_fallback: false,
            })
        }
    }

    struct Truncator;
    impl CleanupEngine for Truncator {
        fn cleanup(&self, _t: &str, _v: bool) -> Result<CleanupOutput, CleanupError> {
            Ok(CleanupOutput {
                text: "ok".into(),
                guard_fallback: false,
            })
        }
    }

    #[test]
    fn guard_rejects_invented_content() {
        let g = Guarded::new(Inventor);
        let out = g
            .cleanup("please review the quarterly numbers before friday", false)
            .unwrap();
        assert!(out.guard_fallback);
        assert!(out.text.to_lowercase().contains("quarterly numbers"));
    }

    #[test]
    fn guard_rejects_dropped_content() {
        let g = Guarded::new(Truncator);
        let out = g
            .cleanup("send the design doc to the whole team today", false)
            .unwrap();
        assert!(out.guard_fallback);
        assert!(out.text.to_lowercase().contains("design doc"));
    }

    #[test]
    fn guard_passes_honest_rule_cleanup() {
        let g = Guarded::new(RuleCleanup::default());
        let out = g
            .cleanup("um so the meeting is uh moved to three pm", false)
            .unwrap();
        assert!(!out.guard_fallback);
        assert_eq!(out.text, "So the meeting is moved to three pm.");
    }

    #[test]
    fn guard_enforces_verbatim_word_identity() {
        struct SneakyVerbatim;
        impl CleanupEngine for SneakyVerbatim {
            fn cleanup(&self, _t: &str, _v: bool) -> Result<CleanupOutput, CleanupError> {
                Ok(CleanupOutput {
                    text: "i said that".into(),
                    guard_fallback: false,
                })
            }
        }
        let g = Guarded::new(SneakyVerbatim);
        let out = g.cleanup("um i said this", true).unwrap();
        assert!(out.guard_fallback);
        assert_eq!(out.text, "um i said this");
    }
}
