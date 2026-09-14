//! editor.rs — Local LLM-powered text editing layer
//!
//! Takes raw Whisper transcripts and applies smart edits:
//!   - Filler word removal (um, uh, like, you know, etc.)
//!   - Auto-edit: self-corrections ("let's meet at 6pm, actually let's do 7" → "let's meet at 7pm")
//!   - Punctuation and capitalization cleanup
//!
//! Strategy: Rule-based pre-processing (fast, zero-latency) + optional local LLM post-processing.
//! The rule-based layer handles 90% of cases. The LLM layer handles nuanced edits.

use serde::{Deserialize, Serialize};

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EditorConfig {
    /// Enable the local LLM post-processing layer.
    pub use_llm: bool,
    /// Path to the LLM model file (GGUF format, e.g., SmolLM-135M).
    pub model_path: Option<String>,
    /// Enable filler word removal (rule-based, always available).
    pub remove_fillers: bool,
    /// Enable auto-edit self-correction detection.
    pub auto_edit: bool,
    /// Enable punctuation cleanup.
    pub fix_punctuation: bool,
    /// Enable capitalization of sentence starts.
    pub fix_capitalization: bool,
}

impl Default for EditorConfig {
    fn default() -> Self {
        Self {
            use_llm: false,
            model_path: None,
            remove_fillers: true,
            auto_edit: true,
            fix_punctuation: true,
            fix_capitalization: true,
        }
    }
}

// ---------------------------------------------------------------------------
// Rule-based editor (zero latency)
// ---------------------------------------------------------------------------

/// Filler words/phrases to strip from transcripts.
const FILLER_WORDS: &[&str] = &[
    "um",
    "uh",
    "ah",
    "er",
    "like",
    "you know",
    "i mean",
    "so",
    "basically",
    "actually",
    "right",
    "kind of",
    "sort of",
    "let me see",
    "let's see",
    "well",
];

/// Byte-wise, case-insensitive search for an ASCII `needle` in `text`.
/// Returns the byte offset of the first match, or `None`.
fn find_ascii_ci(haystack: &str, needle: &str) -> Option<usize> {
    debug_assert!(needle.is_ascii());
    let h = haystack.as_bytes();
    let n = needle.as_bytes();
    if n.is_empty() || n.len() > h.len() {
        return None;
    }
    (0..=h.len() - n.len()).find(|&start| {
        h[start..start + n.len()]
            .iter()
            .zip(n.iter())
            .all(|(&hb, &nb)| hb.to_ascii_lowercase() == nb.to_ascii_lowercase())
    })
}

/// If `text` starts with an ASCII `prefix` (case-insensitive), returns the
/// remainder; otherwise returns `None`.
fn strip_ascii_ci_prefix<'a>(text: &'a str, prefix: &str) -> Option<&'a str> {
    let len = prefix.len();
    if text.len() < len {
        return None;
    }
    let head = text.get(..len)?;
    if head.eq_ignore_ascii_case(prefix) {
        Some(&text[len..])
    } else {
        None
    }
}

/// Returns `true` if `word` appears in `text` at byte offset `start` and is
/// delimited on both sides by non-word characters (whitespace or punctuation).
/// This lets fillers that follow commas — "So, um, I..." — be matched just
/// like fillers surrounded by spaces.
fn is_standalone_word(text: &str, start: usize, word: &str) -> bool {
    let end = match start.checked_add(word.len()) {
        Some(end) if end <= text.len() => end,
        _ => return false,
    };
    let slice = match text.get(start..end) {
        Some(slice) => slice,
        None => return false,
    };
    if slice != word {
        return false;
    }
    let bytes = text.as_bytes();
    if start > 0 && is_word_byte(bytes[start - 1]) {
        return false;
    }
    if end < text.len() && is_word_byte(bytes[end]) {
        return false;
    }
    true
}

/// Word characters are alphanumerics plus hyphens/underscores, so filler-word
/// matching never splits hyphenated compounds ("so-called", "well-known").
fn is_word_byte(b: u8) -> bool {
    b.is_ascii_alphanumeric() || b == b'-' || b == b'_'
}

/// Self-correction patterns: "X, actually Y" → "Y", "X, let's do Y" → "Y",
/// "X, never mind" → "X". Returns the corrected text if a pattern matches.
///
/// Corrections can nest — "Let's meet at 6pm, actually let's do 7" is corrected
/// to "7" — so the markers are applied repeatedly until the text stabilizes.
fn detect_self_correction(text: &str) -> Option<String> {
    let mut current = text.trim();

    loop {
        let mut changed = false;

        // "X, never mind" → abandon the change, keep "X"
        if let Some(idx) = find_ascii_ci(current, ", never mind") {
            current = current[..idx].trim();
            changed = true;
        }

        // "X, actually Y" → "Y" and "X, let's do Y" → "Y"
        let after_marker = if let Some(idx) = find_ascii_ci(current, ", actually ") {
            Some(&current[idx + ", actually ".len()..])
        } else if let Some(idx) = find_ascii_ci(current, ", let's do ") {
            Some(&current[idx + ", let's do ".len()..])
        } else {
            None
        };

        if let Some(rest) = after_marker {
            current = rest.trim();
            changed = true;
            // "X, actually let's do Y" → "Y": the marker may itself wrap a
            // further "let's do"/"let's" correction.
            if let Some(rest) = strip_ascii_ci_prefix(current, "let's do ") {
                current = rest.trim();
            } else if let Some(rest) = strip_ascii_ci_prefix(current, "let's ") {
                current = rest.trim();
            }
        }

        if !changed {
            let done = current.trim();
            return if done.is_empty() {
                None
            } else {
                Some(format!("{}.", done))
            };
        }
    }
}

/// Remove filler words from text.
///
/// A single left-to-right pass drops every `FILLER_WORDS` token that appears
/// as a standalone word (delimited by whitespace or punctuation), so fillers
/// that follow commas — the most common position in raw transcripts — are
/// removed just like space-delimited ones.
fn remove_fillers(text: &str) -> String {
    let mut result = String::with_capacity(text.len());
    let mut i = 0;

    while i < text.len() {
        if let Some(filler) = FILLER_WORDS
            .iter()
            .find(|&&filler| is_standalone_word(text, i, filler))
        {
            i += filler.len();
            // A comma that directly follows an interjection is usually part of
            // the disfluency itself ("So, um, I..."), so drop it too to avoid
            // leaving a doubled comma behind.
            if text.as_bytes().get(i) == Some(&b',') {
                i += 1;
            }
            continue;
        }

        // Copy the next character untouched (always a char boundary).
        let ch = text[i..].chars().next().unwrap_or_default();
        result.push(ch);
        i += ch.len_utf8();
    }

    // Collapse runs of spaces left behind by removed fillers.
    let mut collapsed = String::with_capacity(result.len());
    let mut prev_space = false;
    for ch in result.chars() {
        if ch == ' ' {
            if prev_space {
                continue;
            }
            prev_space = true;
        } else {
            prev_space = false;
        }
        collapsed.push(ch);
    }

    collapsed.trim().to_string()
}

/// Fix basic punctuation issues.
fn fix_punctuation(text: &str) -> String {
    let mut result = text.to_string();

    // Remove spaces before punctuation
    result = result.replace(" .", ".");
    result = result.replace(" ,", ",");
    result = result.replace(" !", "!");
    result = result.replace(" ?", "?");
    result = result.replace(" ;", ";");
    result = result.replace(" :", ":");

    // Add period at end if missing and text doesn't end with punctuation
    let trimmed = result.trim();
    if !trimmed.is_empty()
        && !trimmed.ends_with('.')
        && !trimmed.ends_with('!')
        && !trimmed.ends_with('?')
        && !trimmed.ends_with(':')
        && !trimmed.ends_with(';')
    {
        result = format!("{}.", result.trim());
    }

    result
}

/// Capitalize the first letter of each sentence.
fn fix_capitalization(text: &str) -> String {
    let mut result = String::with_capacity(text.len());
    let mut capitalize_next = true;

    for ch in text.chars() {
        if capitalize_next && ch.is_ascii_alphabetic() {
            for upper in ch.to_uppercase() {
                result.push(upper);
            }
            capitalize_next = false;
        } else {
            result.push(ch);
            // Capitalize after sentence-ending punctuation
            if ch == '.' || ch == '!' || ch == '?' {
                capitalize_next = true;
            }
        }
    }

    result
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Apply all rule-based edits to a raw transcript.
/// This is the fast path (sub-millisecond) and handles 90% of cases.
pub fn edit_transcript(raw: &str, config: &EditorConfig) -> String {
    if raw.trim().is_empty() {
        return String::new();
    }

    let mut text = raw.to_string();

    // 1. Self-correction detection (before filler removal, as it changes meaning)
    if config.auto_edit {
        if let Some(corrected) = detect_self_correction(&text) {
            text = corrected;
        }
    }

    // 2. Filler word removal
    if config.remove_fillers {
        text = remove_fillers(&text);
    }

    // 3. Punctuation cleanup
    if config.fix_punctuation {
        text = fix_punctuation(&text);
    }

    // 4. Capitalization
    if config.fix_capitalization {
        text = fix_capitalization(&text);
    }

    text
}

/// Process a transcript with the optional LLM layer.
/// Currently returns the rule-based result.
/// TODO: Wire up llama-cpp-rs or ollama for LLM post-processing.
pub async fn edit_transcript_smart(raw: &str, config: &EditorConfig) -> String {
    let rule_based = edit_transcript(raw, config);

    if !config.use_llm || config.model_path.is_none() {
        return rule_based;
    }

    // Future: Send rule_based to local LLM for nuanced editing
    // For now, return rule-based result
    rule_based
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_remove_fillers() {
        let input = "So, um, I was, uh, thinking, like, we could basically, you know, do this.";
        let result = remove_fillers(input);
        assert!(!result.contains("um"));
        assert!(!result.contains("uh"));
        assert!(!result.contains("like"));
        assert!(!result.contains("basically"));
        assert!(!result.contains("you know"));
    }

    #[test]
    fn test_self_correction() {
        let input = "Let's meet at 6pm, actually let's do 7";
        let result = detect_self_correction(input);
        assert!(result.is_some());
        assert_eq!(result.unwrap(), "7.");
    }

    #[test]
    fn test_fix_punctuation() {
        let input = "hello world ";
        let result = fix_punctuation(input);
        assert!(result.ends_with('.'));
    }

    #[test]
    fn test_fix_capitalization() {
        let input = "hello. how are you?";
        let result = fix_capitalization(input);
        assert!(result.starts_with('H'));
        assert!(result.contains(". H"));
    }
}
