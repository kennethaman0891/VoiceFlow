use crossbeam_channel::{Receiver, Sender};
use once_cell::sync::Lazy;
use serde::{Deserialize, Serialize};
use std::sync::Mutex;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum AppStatus {
    Idle,
    Recording,
    HandsFree,
    Transcribing,
    Cleaning,
    Success,
    Error,
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
    #[serde(default = "default_silence_timeout_ms")]
    pub silence_timeout_ms: u64,
    #[serde(default = "default_double_click_enabled")]
    pub double_click_enabled: bool,
    #[serde(default = "default_transcribe_shortcut")]
    pub transcribe_shortcut: String,
    #[serde(default = "default_push_to_talk")]
    pub push_to_talk: bool,
    #[serde(default)]
    pub microphone: Option<String>,
    #[serde(default)]
    pub mute_while_recording: bool,
    #[serde(default)]
    pub audio_feedback: bool,
    #[serde(default = "default_feedback_volume")]
    pub feedback_volume: u32,
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
            silence_timeout_ms: default_silence_timeout_ms(),
            double_click_enabled: default_double_click_enabled(),
            transcribe_shortcut: default_transcribe_shortcut(),
            push_to_talk: default_push_to_talk(),
            microphone: None,
            mute_while_recording: false,
            audio_feedback: false,
            feedback_volume: default_feedback_volume(),
        }
    }
}

fn default_transcribe_shortcut() -> String {
    "Left Option + Space".to_string()
}
fn default_push_to_talk() -> bool {
    true
}
fn default_feedback_volume() -> u32 {
    100
}

fn default_language() -> String {
    "en".to_string()
}
fn default_auto_paste() -> bool {
    true
}
fn default_show_mic_widget() -> bool {
    true
}
fn default_whisper_model() -> String {
    "base".to_string()
}
fn default_cleanup_model() -> String {
    "off".to_string()
}
fn default_silence_timeout_ms() -> u64 {
    2000
}
fn default_double_click_enabled() -> bool {
    true
}

pub fn has_saved_settings() -> bool {
    settings_file().map(|path| path.is_file()).unwrap_or(false)
}

fn settings_file() -> Option<std::path::PathBuf> {
    let dir = match std::env::consts::OS {
        "macos" => dirs::home_dir()?.join("Library/Application Support/VoiceFlow"),
        "windows" => dirs::config_dir()?.join("VoiceFlow"),
        "linux" => dirs::data_dir()?.join("voiceflow"),
        _ => dirs::home_dir()?.join(".voiceflow"),
    };
    Some(dir.join("settings.json"))
}

impl AppSettings {
    pub fn load() -> Self {
        let Some(path) = settings_file() else {
            return Self::default();
        };
        match std::fs::read_to_string(&path) {
            Ok(raw) => serde_json::from_str(&raw).unwrap_or_default(),
            Err(_) => Self::default(),
        }
    }

    pub fn save(&self) {
        let Some(path) = settings_file() else {
            return;
        };
        if let Some(parent) = path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        if let Ok(raw) = serde_json::to_string_pretty(self) {
            let _ = std::fs::write(path, raw);
        }
    }
}

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

static APP_STATE: Lazy<Mutex<AppState>> = Lazy::new(|| {
    let (tx, rx) = crossbeam_channel::unbounded();

    std::thread::spawn(move || {
        while let Ok(event) = rx.recv() {
            log::debug!("App event: {:?}", event);
        }
    });

    Mutex::new(AppState {
        settings: Mutex::new(AppSettings::default()),
        current_transcript: Mutex::new(Vec::new()),
        status: Mutex::new(AppStatus::Idle),
        event_tx: Mutex::new(tx),
    })
});

pub fn with_state<F, R>(f: F) -> R
where
    F: FnOnce(&AppState) -> R,
{
    let state = APP_STATE.lock().unwrap();
    f(&state)
}
