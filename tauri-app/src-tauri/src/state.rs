use std::sync::atomic::AtomicBool;
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;

use serde::{Deserialize, Serialize};
use tauri::AppHandle;
use tauri::Emitter;

use crate::audio;
use crate::whisper;

#[derive(Clone, Serialize, Deserialize)]
pub struct Config {
    pub language: String,
    pub model_path: String,
    pub auto_paste: bool,
}

impl Default for Config {
    fn default() -> Self {
        Config {
            language: "en".to_string(),
            model_path: crate::default_model_path().to_string_lossy().into(),
            auto_paste: false,
        }
    }
}

pub struct AppState {
    pub app: AppHandle,
    pub recording: Arc<Mutex<bool>>,
    pub samples: Arc<Mutex<Vec<f32>>>,
    /// Set `true` to tell the capture thread to stop and drop its stream.
    pub stop_flag: Arc<AtomicBool>,
    pub capture_thread: Arc<Mutex<Option<JoinHandle<()>>>>,
    pub capture_rate: Arc<Mutex<u32>>,
    pub engine: Arc<Mutex<Option<whisper_rs::WhisperContext>>>,
    pub config: Arc<Mutex<Config>>,
}

impl AppState {
    pub fn with_config(app: AppHandle, config: Config) -> Self {
        AppState {
            config: Arc::new(Mutex::new(config)),
            ..AppState::new(app)
        }
    }

    pub fn new(app: AppHandle) -> Self {
        AppState {
            app,
            recording: Arc::new(Mutex::new(false)),
            samples: Arc::new(Mutex::new(Vec::new())),
            stop_flag: Arc::new(AtomicBool::new(false)),
            capture_thread: Arc::new(Mutex::new(None)),
            capture_rate: Arc::new(Mutex::new(16000)),
            engine: Arc::new(Mutex::new(None)),
            config: Arc::new(Mutex::new(Config::default())),
        }
    }

    pub fn emit_state(&self, s: &str) {
        let _ = self.app.emit("state-change", s.to_string());
    }

    pub fn toggle(&self) -> Result<String, String> {
        let rec = *self.recording.lock().unwrap();
        if rec {
            self.stop()
        } else {
            self.start()
        }
    }

    fn start(&self) -> Result<String, String> {
        audio::start_capture(self)?;
        *self.recording.lock().unwrap() = true;
        self.emit_state("recording");
        Ok("recording".to_string())
    }

    fn stop(&self) -> Result<String, String> {
        let samples = audio::stop_capture(self);
        *self.recording.lock().unwrap() = false;
        self.emit_state("idle");
        whisper::transcribe(self, samples);
        Ok("idle".to_string())
    }
}
