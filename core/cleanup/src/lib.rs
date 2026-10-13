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
    /// What the rules removed, in the order they ran. Empty when nothing changed or when
    /// the guard fell back (its fallback text applies none of them).
    pub edits: Vec<Edit>,
}

/// One automatic edit, recorded by rule name and size only — never the words, so the log
/// can say what cleanup did without becoming a second, unencrypted transcript. The words
/// themselves stay recoverable: the raw transcript is stored as `transcript_final`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Edit {
    pub rule: &'static str,
    pub words_removed: usize,
}

pub trait CleanupEngine {
    /// `verbatim`: §7 F15 — no semantic change, no filler removal; literal transcript.
    fn cleanup(&self, transcript: &str, verbatim: bool) -> Result<CleanupOutput, CleanupError>;
}

// ---------------------------------------------------------------------------------------------
// Rule-based Phase-0 engine

/// Default filler tokens stripped in dictation mode (single-token; configurable).
const FILLERS: &[&str] = &["um", "uh", "uhh", "erm", "er", "hmm", "mmm", "mm"];

/// Multi-word fillers. Only ever removed when set off by a comma ("it's, you know, fast"):
/// unpunctuated they are usually content ("do you know", "I mean it").
const FILLER_PHRASES: &[&str] = &["you know", "i mean"];

/// Words whose immediate repeat is an ASR-captured stutter ("the the", "I I think"). A short
/// allow-list on purpose: doubles like "no no", "ha ha", "that that", "had had" and "is is"
/// are real speech or real grammar, and so are particle and pronoun doubles ("turn it on on
/// Monday", "log in in", "told you you were") — anything not listed here is left alone.
const STUTTER_WORDS: &[&str] = &[
    "the", "a", "an", "to", "of", "for", "with", "and", "or", "but", "i", "i'm", "we", "it's",
    "my", "our", "your", "el", "de",
];

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
                edits: Vec::new(),
            });
        }
        let mut edits = Vec::new();
        let mut words: Vec<&str> = transcript.split_whitespace().collect();
        words.retain(|w| !self.is_filler(w));
        let (joined, phrase_words) = drop_filler_phrases(&words.join(" "));
        if phrase_words > 0 {
            edits.push(Edit { rule: "filler_phrase", words_removed: phrase_words });
        }
        let (joined, stutters) = collapse_stutters(&joined);
        if stutters > 0 {
            edits.push(Edit { rule: "repetition", words_removed: stutters });
        }
        Ok(CleanupOutput {
            text: finish_sentences(&joined),
            guard_fallback: false,
            edits,
        })
    }
}

// ---------------------------------------------------------------------------------------------
// Clauses: a transcript split at the punctuation the ASR wrote. Rules that need to know
// whether a phrase was set off by commas work on these instead of on raw words.

#[derive(Debug, Clone)]
struct Clause {
    text: String,
    /// The punctuation that closed the clause; None for a trailing, unpunctuated one.
    end: Option<char>,
}

fn is_terminator(c: char) -> bool {
    matches!(c, '.' | '!' | '?')
}

/// Titles and Latin shorthands whose '.' is not a clause end.
const ABBREVIATIONS: &[&str] = &[
    "mr", "mrs", "ms", "dr", "prof", "st", "jr", "sr", "vs", "e.g", "i.e", "etc", "approx",
];

/// Split at clause punctuation followed by whitespace or the end — so "3.30", "google.com"
/// and "U.S" stay inside their clause, and so does "Mr." in "Mr. Jones".
fn split_clauses(s: &str) -> Vec<Clause> {
    let chars: Vec<char> = s.chars().collect();
    let mut out = Vec::new();
    let mut cur = String::new();
    for (i, &c) in chars.iter().enumerate() {
        let abbreviation = c == '.'
            && cur
                .split_whitespace()
                .last()
                .is_some_and(|w| ABBREVIATIONS.contains(&w.to_lowercase().as_str()));
        let closes = matches!(c, ',' | '.' | ';' | ':' | '!' | '?')
            && !abbreviation
            && chars.get(i + 1).map_or(true, |n| n.is_whitespace());
        if closes {
            out.push(Clause { text: cur.trim().to_string(), end: Some(c) });
            cur.clear();
        } else {
            cur.push(c);
        }
    }
    if !cur.trim().is_empty() {
        out.push(Clause { text: cur.trim().to_string(), end: None });
    }
    out
}

fn join_clauses(clauses: &[Clause]) -> String {
    clauses
        .iter()
        .filter(|c| !c.text.is_empty())
        .map(|c| match c.end {
            Some(p) => format!("{}{p}", c.text),
            None => c.text.clone(),
        })
        .collect::<Vec<_>>()
        .join(" ")
}

/// The punctuation left on the clause in front of a removed span that `own` closed. A
/// sentence end in front always stays; otherwise the span's own sentence end (or its
/// absence, at the very end) carries over. `parenthetical`: the span was wrapped in a comma
/// pair (", you know,"), so both commas go.
fn merged_end(prev: Option<char>, own: Option<char>, parenthetical: bool) -> Option<char> {
    if prev.is_some_and(is_terminator) {
        return prev;
    }
    match own {
        Some(c) if is_terminator(c) => own,
        None => None,
        _ if parenthetical && prev == Some(',') => None,
        _ => prev,
    }
}

fn phrase_of(text: &str) -> String {
    text.split_whitespace().collect::<Vec<_>>().join(" ").to_lowercase()
}

/// Remove comma-set-off filler phrases. Returns the text and how many words went.
fn drop_filler_phrases(s: &str) -> (String, usize) {
    let clauses = split_clauses(s);
    if clauses.len() < 2 {
        return (s.to_string(), 0);
    }
    let mut out: Vec<Clause> = Vec::with_capacity(clauses.len());
    let mut removed = 0;
    for c in clauses {
        let phrase = phrase_of(&c.text);
        let set_off = c.end == Some(',') || out.last().is_some_and(|p| p.end == Some(','));
        // "If you know, you know." repeats the phrase on purpose.
        let echoed = out.last().is_some_and(|p| phrase_of(&p.text).ends_with(&phrase));
        if set_off && !echoed && FILLER_PHRASES.contains(&phrase.as_str()) {
            if let Some(prev) = out.last_mut() {
                // A tag's "?" or "!" is the filler's tone, not the statement's: "it's fast,
                // you know?" is a statement.
                let own = c.end.map(|e| if matches!(e, '?' | '!') { '.' } else { e });
                prev.end = merged_end(prev.end, own, true);
            }
            removed += c.text.split_whitespace().count();
            continue;
        }
        out.push(c);
    }
    if removed == 0 {
        return (s.to_string(), 0);
    }
    (join_clauses(&out), removed)
}

/// Spoken self-corrections (§7 F17). Each removes the clause before it.
const SCRATCH_COMMANDS: &[&str] = &["scratch that", "delete that"];

/// Apply "scratch that" / "delete that". A command counts only when it is a whole clause
/// of its own (the ASR punctuated around it) with a real clause before it to remove;
/// anything else is content ("I'll scratch that idea", an unpunctuated run-on), per the
/// blueprint §526 "prefer content" policy; after a colon it is quoted content. Filler
/// clauses in between ("John, um, scratch that") go with it — the speaker meant the clause
/// before the "um". After a comma it removes one clause; as a sentence of its own it removes
/// the sentence before it.
pub fn apply_commands(transcript: &str) -> (String, Vec<Edit>) {
    let clauses = split_clauses(transcript);
    let mut out: Vec<Clause> = Vec::with_capacity(clauses.len());
    let mut removed = 0;
    for c in &clauses {
        // After a colon it is being quoted ("the label is: Delete that"), not spoken.
        let quoted = out.last().is_some_and(|k| k.end == Some(':'));
        if !quoted && SCRATCH_COMMANDS.contains(&phrase_of(&c.text).as_str()) {
            if let Some(v) = out.iter().rposition(|k| !is_filler_clause(&k.text)) {
                // Said after a full stop, it takes back that whole sentence; after a comma,
                // just the clause.
                let start = if out[v].end.is_some_and(is_terminator) {
                    out[..v]
                        .iter()
                        .rposition(|k| k.end.is_some_and(is_terminator))
                        .map_or(0, |p| p + 1)
                } else {
                    v
                };
                let gone: usize = out
                    .drain(start..)
                    .map(|k| k.text.split_whitespace().count())
                    .sum();
                if let Some(prev) = out.last_mut() {
                    prev.end = merged_end(prev.end, c.end, false);
                }
                removed += gone + c.text.split_whitespace().count();
                continue;
            }
        }
        out.push(c.clone());
    }
    if removed == 0 {
        return (transcript.to_string(), Vec::new());
    }
    (join_clauses(&out), vec![Edit { rule: "scratch_that", words_removed: removed }])
}

/// A clause that is nothing but filler ("um", "you know").
fn is_filler_clause(text: &str) -> bool {
    let phrase = phrase_of(text);
    FILLER_PHRASES.contains(&phrase.as_str())
        || phrase.split_whitespace().all(|w| {
            let bare: String = w.chars().filter(|c| c.is_alphanumeric()).collect();
            FILLERS.contains(&bare.as_str())
        })
}

/// Collapse an immediate repeat of a STUTTER_WORDS word. The first copy must carry no
/// punctuation — "to, to be honest" is two deliberate words.
fn collapse_stutters(s: &str) -> (String, usize) {
    let words: Vec<&str> = s.split_whitespace().collect();
    let bare = |w: &str| w.trim_matches(|c: char| !c.is_alphanumeric() && c != '\'').to_lowercase();
    let mut out = Vec::with_capacity(words.len());
    let mut removed = 0;
    for (i, w) in words.iter().enumerate() {
        let plain = w.chars().all(|c| c.is_alphabetic() || c == '\'');
        // "vitamin A a day": a capital letter used as a label, then the article.
        let label = w.chars().count() == 1
            && w.chars().all(char::is_uppercase)
            && words.get(i + 1) != Some(w);
        let repeated = !label && words.get(i + 1).is_some_and(|n| bare(n) == bare(w));
        if plain && repeated && STUTTER_WORDS.contains(&bare(w).as_str()) {
            removed += 1;
            continue;
        }
        out.push(*w);
    }
    (out.join(" "), removed)
}

/// Whitespace normalization only — the "lightly cleaned verbatim" guard fallback (§17.2).
pub fn normalize_ws(s: &str) -> String {
    s.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// Capitalize sentence starts, standalone "i", tidy space-before-punctuation, ensure terminal
/// punctuation, repair question marks on interrogative-worded sentences.
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
            // ASR sometimes glues sentences ("out there.I don't know", live 2026-07-19):
            // lowercase before + uppercase after = a missing boundary space. The guards
            // keep "U.S." (uppercase before) and "google.com" (lowercase after) intact.
            let prev_lower = out.chars().rev().nth(1).is_some_and(|p| p.is_lowercase());
            let next_upper = chars.peek().is_some_and(|n| n.is_uppercase());
            if prev_lower && next_upper {
                out.push(' ');
                cap_next = true;
            } else if matches!(chars.peek(), None | Some(' ')) {
                // Sentence boundary only when followed by space/end — a '.' inside
                // "3.30" is not one (was capitalizing the word after a decimal). An
                // acronym-final '.' ("U.S. office") isn't one either: single capital
                // letter preceded by its own dot.
                let mut rev = out.chars().rev().skip(1);
                let acronym =
                    rev.next().is_some_and(|p| p.is_uppercase()) && rev.next() == Some('.');
                if !acronym {
                    cap_next = true;
                }
            }
        }
    }
    let mut text = fix_standalone_i(&out);
    if let Some(last) = text.chars().last() {
        if !matches!(last, '.' | '!' | '?' | '…' | ':') {
            text.push('.');
        }
    }
    repair_question_marks(&text)
}

/// ASR punctuates from wording, not intonation, so questions phrased as questions still
/// arrive with a terminal '.' surprisingly often. Flip '.' → '?' ONLY for sentences whose
/// wording is unambiguously interrogative: a wh-word lead, an auxiliary+pronoun inversion
/// ("can we…", "is it…"), or a tag question (", right"). Intonation-only questions
/// ("this works.") are left alone — a wrong '?' on a statement is worse than a wrong '.'
/// on a question.
fn repair_question_marks(text: &str) -> String {
    let chars: Vec<char> = text.chars().collect();
    let mut out = String::with_capacity(text.len());
    let mut start = 0;
    for i in 0..chars.len() {
        let c = chars[i];
        let boundary = matches!(c, '.' | '!' | '?')
            && (i + 1 == chars.len() || chars[i + 1] == ' ');
        if boundary {
            let sentence: String = chars[start..i].iter().collect();
            out.push_str(&sentence);
            out.push(if c == '.' && is_interrogative(&sentence) { '?' } else { c });
            start = i + 1;
        }
    }
    if start < chars.len() {
        out.extend(&chars[start..]);
    }
    out
}

fn is_interrogative(sentence: &str) -> bool {
    const LEADS: &[&str] = &["okay", "ok", "so", "well", "now", "but", "and", "hey", "then", "also"];
    const WH: &[&str] = &["what", "why", "how", "where", "when", "who", "whose", "whom", "which"];
    const AUX: &[&str] = &[
        "am", "is", "are", "was", "were", "do", "does", "did", "can", "could", "will",
        "would", "shall", "should", "may", "might", "must", "have", "has", "had", "isn't",
        "aren't", "wasn't", "weren't", "don't", "doesn't", "didn't", "can't", "couldn't",
        "won't", "wouldn't", "shouldn't", "haven't", "hasn't", "hadn't",
    ];
    const PRONOUNS: &[&str] = &[
        "i", "you", "we", "they", "he", "she", "it", "this", "that", "these", "those",
        "there", "anyone", "anybody", "someone", "somebody", "everyone", "everybody",
        "anything", "something",
    ];
    // Tag question: "…, right" (comma required — "the answer is no" is not one).
    let lower = sentence.trim_end().to_lowercase();
    for tag in ["right", "no", "correct", "yeah"] {
        if lower.ends_with(&format!(", {tag}")) {
            return true;
        }
    }
    let words: Vec<String> = sentence
        .split_whitespace()
        .map(|w| {
            w.trim_matches(|c: char| !c.is_alphanumeric() && c != '\'')
                .to_lowercase()
        })
        .collect();
    let mut i = 0;
    while i < words.len() && LEADS.contains(&words[i].as_str()) {
        i += 1;
    }
    let (Some(first), second) = (words.get(i), words.get(i + 1)) else {
        return false;
    };
    if WH.contains(&first.as_str()) {
        // "how to reset…", "what a mess" — instructional/exclamatory, not questions.
        return !matches!(second.map(String::as_str), Some("to") | Some("a") | Some("an"));
    }
    // Auxiliary + pronoun inversion ("can we", "is it") — but not imperatives ("do the
    // dishes"), whose next word is not a pronoun.
    AUX.contains(&first.as_str())
        && second.map(|w| PRONOUNS.contains(&w.as_str())).unwrap_or(false)
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
        if verbatim {
            return self.check(transcript, true);
        }
        // Spoken commands run first, outside the engine: they are the user's explicit
        // instruction, not an inference, so the guard measures the engine against the
        // commanded text. The raw words stay in history as `transcript_final`.
        let (commanded, mut edits) = apply_commands(transcript);
        let mut out = self.check(&commanded, false)?;
        edits.append(&mut out.edits);
        out.edits = edits;
        Ok(out)
    }
}

impl<E: CleanupEngine> Guarded<E> {
    fn check(&self, transcript: &str, verbatim: bool) -> Result<CleanupOutput, CleanupError> {
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
                    edits: Vec::new(),
                }
            });
        }
        // Measure against the transcript with set-off filler phrases already gone, the same
        // way single fillers never count: removing "you know" is not lost meaning, and on a
        // short utterance it would otherwise trip the floor by itself.
        let basis = drop_filler_phrases(&normalize_ws(transcript)).0;
        let input_words = content_words(&basis);
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
        let in_len = basis.chars().count().max(1) as f64;
        let out_len = normalize_ws(&out.text).chars().count() as f64;
        let ratio = out_len / in_len;
        if retention < self.min_retention || ratio < self.len_ratio.0 || ratio > self.len_ratio.1 {
            Ok(CleanupOutput {
                text: finish_sentences(&normalize_ws(transcript)),
                guard_fallback: true,
                edits: Vec::new(),
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
            "Hello there. How are you?"
        );
    }

    #[test]
    fn glued_sentences_get_a_boundary_space() {
        assert_eq!(
            clean("putting that out there.I don't know"),
            "Putting that out there. I don't know."
        );
        // Acronyms and URLs must not be split — and an acronym's final '.' is not a
        // sentence end ("office" stays lowercase).
        assert_eq!(clean("the U.S. office is closed"), "The U.S. office is closed.");
        assert_eq!(clean("check google.com for it"), "Check google.com for it.");
    }

    #[test]
    fn decimal_points_are_not_sentence_boundaries() {
        assert_eq!(
            clean("push the meeting to 3.30 instead"),
            "Push the meeting to 3.30 instead."
        );
    }

    #[test]
    fn interrogative_wording_gets_a_question_mark() {
        // Auxiliary + pronoun inversion.
        assert_eq!(clean("can we ship this on friday."), "Can we ship this on friday?");
        assert_eq!(clean("is it ready yet"), "Is it ready yet?");
        // Wh-lead, including through discourse markers.
        assert_eq!(clean("okay so what time is the demo."), "Okay so what time is the demo?");
        // Tag question (the ", right/no" dictation pattern).
        assert_eq!(
            clean("so you're telling me it works, right."),
            "So you're telling me it works, right?"
        );
    }

    #[test]
    fn declaratives_and_imperatives_keep_their_period() {
        assert_eq!(clean("do the dishes before you leave"), "Do the dishes before you leave.");
        assert_eq!(clean("how to reset the router."), "How to reset the router.");
        assert_eq!(clean("the answer is no"), "The answer is no.");
        // Intonation-only questions stay untouched by design (wrong '?' is worse).
        assert_eq!(clean("this actually works."), "This actually works.");
        // Existing '?' and '!' are never rewritten.
        assert_eq!(clean("we shipped it!"), "We shipped it!");
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

    // ---- repetition + filler phrases (audit 2026-10-11, roadmap step 3) ----

    #[test]
    fn stuttered_function_words_collapse() {
        assert_eq!(clean("the the meeting is at noon"), "The meeting is at noon.");
        assert_eq!(clean("i i think we should go to to the store"), "I think we should go to the store.");
        // A removed filler can leave a stutter behind; it collapses too.
        assert_eq!(clean("send it to the um the team"), "Send it to the team.");
    }

    #[test]
    fn meaningful_doubles_survive() {
        assert_eq!(clean("no no that is wrong"), "No no that is wrong.");
        assert_eq!(clean("ha ha very funny"), "Ha ha very funny.");
        assert_eq!(clean("i said that that was fine"), "I said that that was fine.");
        assert_eq!(clean("she said what it is is a bug"), "She said what it is is a bug.");
        assert_eq!(clean("she had had enough"), "She had had enough.");
        // Punctuation between the two means the speaker chose both.
        assert_eq!(clean("to, to be honest"), "To, to be honest.");
    }

    #[test]
    fn set_off_filler_phrases_are_removed() {
        assert_eq!(clean("it's, you know, really fast"), "It's really fast.");
        assert_eq!(clean("i mean, it works"), "It works.");
        assert_eq!(clean("it ships today, you know."), "It ships today.");
        assert_eq!(clean("done. you know, it was easy"), "Done. It was easy.");
    }

    #[test]
    fn filler_phrases_that_carry_meaning_stay() {
        assert_eq!(clean("do you know where it is"), "Do you know where it is?");
        assert_eq!(clean("i mean it"), "I mean it.");
        assert_eq!(clean("she knows what i mean"), "She knows what I mean.");
        assert_eq!(clean("you know."), "You know.");
        // The idiom repeats the phrase on purpose.
        assert_eq!(clean("if you know, you know."), "If you know, you know.");
    }

    #[test]
    fn a_filler_tag_does_not_turn_a_statement_into_a_question() {
        assert_eq!(clean("it's really fast, you know?"), "It's really fast.");
        assert_eq!(clean("it works, i mean!"), "It works.");
    }

    #[test]
    fn particle_and_pronoun_doubles_are_grammar() {
        assert_eq!(clean("turn it on on monday"), "Turn it on on monday.");
        assert_eq!(clean("log in in the morning"), "Log in in the morning.");
        assert_eq!(clean("i told you you were right"), "I told you you were right.");
        // A capital letter used as a label is not a stuttered article.
        assert_eq!(clean("take vitamin A a day"), "Take vitamin A a day.");
    }

    #[test]
    fn rule_edits_are_reported_without_their_words() {
        let out = RuleCleanup::default()
            .cleanup("the the plan is, you know, fine", false)
            .unwrap();
        assert_eq!(out.text, "The plan is fine.");
        assert_eq!(
            out.edits,
            vec![
                Edit { rule: "filler_phrase", words_removed: 2 },
                Edit { rule: "repetition", words_removed: 1 },
            ]
        );
        let plain = RuleCleanup::default().cleanup("all good", false).unwrap();
        assert!(plain.edits.is_empty());
    }

    #[test]
    fn guard_accepts_filler_phrase_removal_on_short_utterances() {
        // Without phrase-aware retention, 4 of 6 words "lost" trips the 0.6 floor and the
        // filler comes back.
        let g = Guarded::new(RuleCleanup::default());
        let out = g.cleanup("i mean, you know, it works", false).unwrap();
        assert!(!out.guard_fallback);
        assert_eq!(out.text, "It works.");
    }

    // ---- "scratch that" / "delete that" (audit 2026-10-11, roadmap step 4) ----

    fn guarded(s: &str) -> CleanupOutput {
        Guarded::new(RuleCleanup::default()).cleanup(s, false).unwrap()
    }

    #[test]
    fn scratch_that_removes_the_clause_before_it() {
        assert_eq!(guarded("Send it to John, scratch that, send it to Mary.").text, "Send it to Mary.");
        assert_eq!(
            guarded("Meet at the office, on Tuesday, scratch that, Wednesday.").text,
            "Meet at the office, Wednesday."
        );
        assert_eq!(
            guarded("We ship Monday, then test, scratch that. We test first.").text,
            "We ship Monday. We test first."
        );
        assert_eq!(guarded("Send it to John. Delete that. Send it to Mary.").text, "Send it to Mary.");
    }

    #[test]
    fn scratch_that_inside_a_sentence_is_content() {
        assert_eq!(guarded("I'll scratch that idea from the list.").text, "I'll scratch that idea from the list.");
        assert_eq!(guarded("Can you delete that.").text, "Can you delete that?");
        // Nothing before it to remove: the words were meant as words.
        assert_eq!(guarded("Delete that.").text, "Delete that.");
        // No punctuation means no evidence it was spoken as a command — prefer content.
        assert_eq!(
            guarded("send it to john scratch that send it to mary").text,
            "Send it to john scratch that send it to mary."
        );
    }

    #[test]
    fn scratch_that_skips_filler_to_reach_the_clause_meant() {
        // Review #22: the filler clause right before the command was being "scratched".
        assert_eq!(guarded("Send it to John, um, scratch that, send it to Mary.").text, "Send it to Mary.");
        assert_eq!(
            guarded("Send it to John, you know, scratch that, send it to Mary.").text,
            "Send it to Mary."
        );
        // Only filler before it: nothing meant to remove, so it is content.
        assert_eq!(guarded("Um, scratch that.").text, "Scratch that.");
    }

    #[test]
    fn abbreviations_do_not_split_the_scratched_clause() {
        assert_eq!(guarded("Call Mr. Jones, scratch that, call Ann.").text, "Call Ann.");
    }

    #[test]
    fn scratch_that_as_its_own_sentence_takes_back_the_sentence() {
        // After a full stop the speaker is retracting the sentence, not its last clause.
        assert_eq!(guarded("I'll call him tomorrow, after lunch. Scratch that.").text, "");
        assert_eq!(
            guarded("Book the room. I'll call him tomorrow, after lunch. Scratch that. Email him.").text,
            "Book the room. Email him."
        );
    }

    #[test]
    fn a_command_after_a_colon_is_quoted_content() {
        assert_eq!(
            guarded("The button label is: Delete that.").text,
            "The button label is: Delete that."
        );
    }

    #[test]
    fn scratching_everything_leaves_nothing() {
        let out = guarded("Meet Tuesday. Scratch that.");
        assert_eq!(out.text, "");
        assert!(!out.guard_fallback);
    }

    #[test]
    fn scratch_that_is_reported_and_verbatim_ignores_it() {
        let out = guarded("Send it to John, scratch that, send it to Mary.");
        assert_eq!(out.edits, vec![Edit { rule: "scratch_that", words_removed: 6 }]);
        let lit = Guarded::new(RuleCleanup::default())
            .cleanup("send it to john, scratch that, send it to mary", true)
            .unwrap();
        assert_eq!(lit.text, "send it to john, scratch that, send it to mary");
        assert!(lit.edits.is_empty());
    }

    #[test]
    fn guard_floor_still_holds_after_a_command() {
        let out = Guarded::new(Inventor)
            .cleanup("send it monday, scratch that, review the quarterly numbers", false)
            .unwrap();
        assert!(out.guard_fallback);
        assert_eq!(out.text, "Review the quarterly numbers.");
        assert_eq!(out.edits, vec![Edit { rule: "scratch_that", words_removed: 5 }]);
    }

    // ---- guard ----

    struct Inventor;
    impl CleanupEngine for Inventor {
        fn cleanup(&self, _t: &str, _v: bool) -> Result<CleanupOutput, CleanupError> {
            Ok(CleanupOutput {
                text: "I hereby resign effective immediately.".into(),
                guard_fallback: false,
                edits: Vec::new(),
            })
        }
    }

    struct Truncator;
    impl CleanupEngine for Truncator {
        fn cleanup(&self, _t: &str, _v: bool) -> Result<CleanupOutput, CleanupError> {
            Ok(CleanupOutput {
                text: "ok".into(),
                guard_fallback: false,
                edits: Vec::new(),
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
                    edits: Vec::new(),
                })
            }
        }
        let g = Guarded::new(SneakyVerbatim);
        let out = g.cleanup("um i said this", true).unwrap();
        assert!(out.guard_fallback);
        assert_eq!(out.text, "um i said this");
    }
}
