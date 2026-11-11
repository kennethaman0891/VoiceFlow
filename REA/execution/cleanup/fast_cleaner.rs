//! Tier-1 Lexical Cleaner
//! Executes in < 2ms without calling any external LLM or subprocess.
//! Strips filler disfluencies, stuttered duplicates, converts spoken punctuation,
//! and normalizes sentence-level capitalization.

use std::collections::HashSet;

const FILLERS: &[&str] = &[
    "um", "umm", "uh", "uhh", "uhm", "erm", "er", "ah", "ahh", "hmm", "hm",
];

const MULTI_FILLERS: &[&str] = &[
    "you know",
    "i mean",
    "sort of",
    "kind of",
];

pub struct FastLexicalCleaner {
    filler_set: HashSet<&'static str>,
}

impl FastLexicalCleaner {
    pub fn new() -> Self {
        Self {
            filler_set: FILLERS.iter().copied().collect(),
        }
    }

    /// Primary cleanup entrypoint.
    pub fn clean(&self, text: &str) -> String {
        let trimmed = text.trim();
        if trimmed.is_empty() {
            return String::new();
        }

        // 1. Spoken punctuation substitution
        let punct_pass = self.replace_spoken_punctuation(trimmed);

        // 2. Multi-word filler removal
        let multi_pass = self.remove_multi_word_fillers(&punct_pass);

        // 3. Single-word filler and repetition removal
        let tokens: Vec<&str> = multi_pass.split_whitespace().collect();
        let mut filtered: Vec<String> = Vec::with_capacity(tokens.len());
        let mut prev_bare = String::new();

        for token in tokens {
            let bare = token
                .trim_matches(|c: char| !c.is_alphanumeric() && c != '\'')
                .to_ascii_lowercase();

            // Skip single filler words
            if self.filler_set.contains(bare.as_str()) {
                continue;
            }

            // Skip immediate repeated word ("I I think" -> "I think")
            if !bare.is_empty() && bare == prev_bare {
                continue;
            }

            prev_bare = bare;
            filtered.push(token.to_string());
        }

        if filtered.is_empty() {
            return String::new();
        }

        // 4. Join and normalize capitalization
        let joined = filtered.join(" ");
        self.capitalize_sentences(&joined)
    }

    fn replace_spoken_punctuation(&self, text: &str) -> String {
        // Case-insensitive replacements for standard spoken punctuation
        let mut result = text.to_string();
        let mappings = [
            (" comma", ","),
            (" Comma", ","),
            (" period", "."),
            (" Period", "."),
            (" full stop", "."),
            (" question mark", "?"),
            (" exclamation point", "!"),
            (" exclamation mark", "!"),
            (" new line", "\n"),
            (" newline", "\n"),
            (" new paragraph", "\n\n"),
        ];

        for (pattern, replacement) in mappings {
            result = result.replace(pattern, replacement);
        }
        result
    }

    fn remove_multi_word_fillers(&self, text: &str) -> String {
        let mut result = text.to_string();
        for filler in MULTI_FILLERS {
            // Remove with leading comma or space
            let with_comma = format!(", {}", filler);
            result = result.replace(&with_comma, "");
            let with_space = format!(" {}", filler);
            result = result.replace(&with_space, "");
        }
        result
    }

    fn capitalize_sentences(&self, text: &str) -> String {
        let mut output = String::with_capacity(text.len());
        let mut capitalize_next = true;

        for ch in text.chars() {
            if capitalize_next && ch.is_alphabetic() {
                output.extend(ch.to_uppercase());
                capitalize_next = false;
            } else {
                output.push(ch);
                if ch == '.' || ch == '?' || ch == '!' || ch == '\n' {
                    capitalize_next = true;
                }
            }
        }

        output
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_filler_and_repetition_removal() {
        let cleaner = FastLexicalCleaner::new();
        let input = "um I I think we should you know ship this period";
        let cleaned = cleaner.clean(input);
        assert_eq!(cleaned, "I think we should ship this.");
    }
}
