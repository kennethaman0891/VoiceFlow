use crate::state::AppState;
use tauri::Emitter;

/// Resample `samples` (captured at `from_rate`) down to 16 kHz mono, which is
/// what Whisper expects.
fn resample_to_16k(samples: &[f32], from_rate: u32) -> Result<Vec<f32>, String> {
    if from_rate == 16000 {
        return Ok(samples.to_vec());
    }
    samplerate::convert(
        from_rate,
        16000,
        1,
        samplerate::ConverterType::SincMediumQuality,
        samples,
    )
    .map_err(|e| format!("resample failed: {:?}", e))
}

/// Load (and cache) the Whisper model, then transcribe samples off-thread and
/// emit the resulting text via the `transcript` event.
pub fn transcribe(state: &AppState, samples: Vec<f32>) {
    let app = state.app.clone();
    let engine = state.engine.clone();
    let cfg = state.config.lock().unwrap().clone();
    let from_rate = *state.capture_rate.lock().unwrap();

    std::thread::spawn(move || {
        let audio = match resample_to_16k(&samples, from_rate) {
            Ok(a) => a,
            Err(e) => {
                let _ = app.emit("error", e);
                return;
            }
        };

        if audio.is_empty() {
            let _ = app.emit("error", "No audio captured".to_string());
            return;
        }

        let lang = if cfg.language == "auto" {
            None
        } else {
            Some(cfg.language.as_str())
        };

        // Lock the (cached) model for the duration of the transcription.
        let mut g = engine.lock().unwrap();
        let ctx = match g.as_mut() {
            Some(c) => c,
            None => {
                let c = match whisper_rs::WhisperContext::new(&cfg.model_path) {
                    Ok(c) => c,
                    Err(e) => {
                        let _ = app.emit(
                            "error",
                            format!("Failed to load model `{}`: {:?}", cfg.model_path, e),
                        );
                        return;
                    }
                };
                *g = Some(c);
                g.as_mut().unwrap()
            }
        };

        let mut params = whisper_rs::FullParams::new(whisper_rs::SamplingStrategy::Greedy {
            best_of: 0,
        });
        params.set_language(lang);
        params.set_print_special(false);
        params.set_print_progress(false);
        params.set_print_realtime(false);

        if let Err(e) = ctx.full(params, &audio) {
            let _ = app.emit("error", format!("transcribe: {:?}", e));
            return;
        }

        let n = ctx.full_n_segments();
        let mut text = String::new();
        for i in 0..n {
            if let Ok(seg) = ctx.full_get_segment_text(i) {
                text.push_str(&seg);
                text.push(' ');
            }
        }
        let text = text.trim().to_string();
        if !text.is_empty() {
            let _ = app.emit("transcript", text);
        }
    });
}
