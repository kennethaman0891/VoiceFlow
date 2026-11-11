use anyhow::{Context, Result};
use std::path::Path;

/// Local whisper.cpp context. One instance lives for the process.
pub struct WhisperEngine {
    ctx: whisper_rs::WhisperContext,
}

impl WhisperEngine {
    pub fn load(model_path: &Path) -> Result<Self> {
        if !model_path.is_file() {
            anyhow::bail!("Model file does not exist: {}", model_path.display());
        }
        let path = model_path
            .to_str()
            .context("Model path is not valid UTF-8")?;
        let ctx = whisper_rs::WhisperContext::new_with_params(
            path,
            whisper_rs::WhisperContextParameters::default(),
        )
        .context("Failed to load whisper model")?;
        log::info!("Loaded whisper model from {}", model_path.display());
        Ok(Self { ctx })
    }

    /// Transcribe 16 kHz mono f32 samples. Returns an empty string for silence.
    pub fn transcribe(&self, samples: &[f32], threads: i32, language: &str) -> Result<String> {
        if samples.len() < 4_800 {
            return Ok(String::new());
        }
        let mut state = self
            .ctx
            .create_state()
            .context("Failed to create whisper state")?;
        let mut params =
            whisper_rs::FullParams::new(whisper_rs::SamplingStrategy::Greedy { best_of: 1 });
        let threads = threads.clamp(1, 8);
        params.set_n_threads(threads);
        let lang = if language == "auto" { None } else { Some(language) };
        params.set_language(lang);
        params.set_translate(false);
        params.set_no_context(true);
        params.set_print_progress(false);
        params.set_print_realtime(false);
        params.set_print_timestamps(false);
        params.set_suppress_blank(true);
        params.set_single_segment(false);

        state
            .full(params, samples)
            .context("Whisper transcription failed")?;

        let n = state
            .full_n_segments()
            .context("Failed to read whisper segments")?;
        let mut parts = Vec::with_capacity(n as usize);
        for i in 0..n {
            let text = state
                .full_get_segment_text(i)
                .context("Failed to read a whisper segment")?;
            if !text.trim().is_empty() {
                parts.push(text);
            }
        }
        Ok(parts.join(" ").trim().to_string())
    }
}

const FILLERS: &[&str] = &[
    "um", "umm", "uh", "uhh", "uhm", "erm", "er", "ah", "ahh", "hmm", "hm", "mm",
];

/// Fast filler and capitalization pass. This does not call a language model.
pub fn polish_transcript(raw: &str) -> String {
    let mut words = Vec::new();
    for token in raw.split_whitespace() {
        let bare = token
            .trim_matches(|c: char| !c.is_ascii_alphanumeric() && c != '\'')
            .to_ascii_lowercase();
        if FILLERS.contains(&bare.as_str()) {
            continue;
        }
        if !token.is_empty() {
            words.push(token.to_string());
        }
    }
    if words.is_empty() {
        return String::new();
    }

    let mut text = words.join(" ");
    text = text
        .replace(" i ", " I ")
        .replace(" i'", " I'");
    if text.starts_with("i ") {
        text.replace_range(0..1, "I");
    } else if text == "i" {
        text = "I".to_string();
    }
    if let Some(first) = text.chars().next() {
        if first.is_ascii_lowercase() {
            let upper = first.to_ascii_uppercase().to_string();
            text.replace_range(..first.len_utf8(), &upper);
        }
    }
    if !text.ends_with(['.', '!', '?']) {
        text.push('.');
    }
    text
}

/// What the HUD should do after a transcription attempt.
pub fn settle_transcript(result: Result<String, String>, cancelled: bool) -> &'static str {
    if cancelled {
        return "idle";
    }
    match result {
        Ok(text) if text.trim().is_empty() => "idle",
        Ok(_) => "success",
        Err(_) => "error",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn polish_removes_fillers_and_fixes_i() {
        assert_eq!(
            polish_transcript("um i think uh she said hi"),
            "I think she said hi."
        );
    }

    #[test]
    fn polish_keeps_words_that_only_look_like_fillers() {
        let text = polish_transcript("she is here and her book");
        assert!(text.contains("her"));
        assert!(text.starts_with("She"));
    }

    #[test]
    fn empty_or_cancelled_work_does_not_look_like_success() {
        assert_eq!(settle_transcript(Ok(String::new()), false), "idle");
        assert_eq!(
            settle_transcript(Ok("hello".into()), true),
            "idle"
        );
        assert_eq!(
            settle_transcript(Err("missing model".into()), false),
            "error"
        );
        assert_eq!(settle_transcript(Ok("hello".into()), false), "success");
    }
}
