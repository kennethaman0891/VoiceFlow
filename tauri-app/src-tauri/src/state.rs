use std::sync::Mutex;
use serde::{Deserialize, Serialize};
use once_cell::sync::Lazy;
use crossbeam_channel::{Sender, Receiver};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "lowercase")]
pub enum AppStatus {
    Idle,
    Recording,
    Transcribing,
    Cleaning,
    Error(String),
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AppSettings {
    #[serde(default = "default_language")]
    pub language: String,
    #[serde(default = "default_auto_paste")]
    pub auto_paste: bool,
    #[serde(default = "default_show_mic_widget")]
    pub show_mic_widget: bool,
    #[serde(default)]
    pub output_device: Option<String>,
    #[serde(default = "default_whisper_model")]
    pub whisper_model: String,
    #[serde(default = "default_cleanup_model")]
    pub cleanup_model: String,
}

impl Default for AppSettings {
    fn default() -> Self {
        Self {
            language: default_language(),
            auto_paste: default_auto_paste(),
            show_mic_widget: default_show_mic_widget(),
            output_device: None,
            whisper_model: default_whisper_model(),
            cleanup_model: default_cleanup_model(),
        }
    }
}

fn default_language() -> String { "en".to_string() }
fn default_auto_paste() -> bool { true }
fn default_show_mic_widget() -> bool { true }
fn default_whisper_model() -> String { "medium".to_string() }
fn default_cleanup_model() -> String { "off".to_string() }

#[derive(Debug, Clone)]
pub enum AppEvent {
    StatusChanged(AppStatus),
    Transcript(String),
    Error(String),
    RecordingStarted,
    RecordingStopped,
}

pub struct AppState {
    pub settings: Mutex<AppSettings>,
    pub current_transcript: Mutex<Vec<String>>,
    pub status: Mutex<AppStatus>,
    pub event_tx: Mutex<Sender<AppEvent>>,
}

impl AppState {
    pub fn new() -> Self {
        let (tx, rx) = crossbeam_channel::unbounded();

        // Spawn receiver task
        std::thread::spawn(move || {
            while let Ok(event) = rx.recv() {
                match &event {
                    AppEvent::StatusChanged(s) => {
                        log::info!("Status changed: {:?}", s);
                    }
                    AppEvent::Transcript(t) => {
                        log::info!("Transcript received: {}", t.chars().take(50).collect::<String>());
                    }
                    AppEvent::Error(e) => {
                        log::warn!("App error: {}", e);
                    }
                    _ => {}
                }
            }
        });

        AppState {
            settings: Mutex::new(AppSettings::default()),
            current_transcript: Mutex::new(Vec::new()),
            status: Mutex::new(AppStatus::Idle),
            event_tx: Mutex::new(tx),
        }
    }

    pub fn emit(&self, event: AppEvent) {
        if let Ok(tx) = self.event_tx.lock() {
            let _ = tx.send(event);
        }
    }

    pub fn set_status(&self, status: AppStatus) {
        *self.status.lock().unwrap() = status.clone();
        self.emit(AppEvent::StatusChanged(status));
    }
}

impl Default for AppState {
    fn default() -> Self {
        Self::new()
    }
}

// Module-level singleton
pub static APP_STATE: Lazy<Mutex<AppState>> = Lazy::new(|| Mutex::new(AppState::new()));

pub fn get_state() -> &'static Mutex<AppState> {
    &APP_STATE
}

/// Helper to lock and access AppState fields
pub fn with_state<F, R>(f: F) -> R
where
    F: FnOnce(&mut AppState) -> R,
{
    let mut state = APP_STATE.lock().unwrap();
    f(&mut state)
}
