#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::env::current_exe;
use std::path::PathBuf;

use tauri::image::Image;
use tauri::menu::{Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::TrayIconBuilder;
use tauri::{Emitter, Manager};
use tauri_plugin_global_shortcut::GlobalShortcutExt;

mod audio;
mod editor;
mod state;
mod whisper;
mod whisperflow;

use editor::EditorConfig;
use state::{AppState, Config};
use whisperflow::WhisperFlowConfig;

use std::sync::Mutex;
use tokio::sync::mpsc;

/// Global state for the WhisperFlow streaming engine.
struct WhisperFlowState {
    /// Channel sender to send audio chunks to the streaming engine.
    sender: Mutex<Option<mpsc::Sender<whisperflow::AudioMessage>>>,
    /// Current configuration.
    config: Mutex<WhisperFlowConfig>,
    /// Editor configuration.
    editor_config: Mutex<EditorConfig>,
}

/// Resolve the Groq API key with a robust precedence order.
///
/// 1. Already-set process env var `GROQ_API_KEY`.
/// 2. `dotenv::dotenv()` which reads `.env` from the current working directory.
/// 3. Explicit candidate paths (some of which mirror the `.env` locations that
///    Tauri uses across dev / bundled layouts):
///      - CWD/.env
///      - CWD/../.env
///      - exe_dir/../.env
///      - exe_dir/../../.env  (exe_dir = current_exe().parent())
///      - /Users/kennethaman/VoiceFlow/.env   (known project root)
/// The first source that yields a non-empty `GROQ_API_KEY` wins.
fn resolve_groq_api_key() -> String {
    // (a) process env var already set
    if let Ok(v) = std::env::var("GROQ_API_KEY") {
        if !v.trim().is_empty() {
            return v;
        }
    }

    // (b) dotenv::dotenv() from the current working directory
    let _ = dotenv::dotenv();
    if let Ok(v) = std::env::var("GROQ_API_KEY") {
        if !v.trim().is_empty() {
            return v;
        }
    }

    // (c) search candidate paths in order
    let cwd = std::env::current_dir().unwrap_or_default();
    let exe_dir = current_exe()
        .ok()
        .and_then(|p| p.parent().map(|d| d.to_path_buf()))
        .unwrap_or_default();

    let candidates = [
        cwd.join(".env"),
        cwd.join("../.env"),
        exe_dir.join("../.env"),
        exe_dir.join("../../.env"),
        PathBuf::from("/Users/kennethaman/VoiceFlow/.env"),
    ];

    for path in candidates {
        if path.is_file() {
            let _ = dotenv::from_path(&path);
            if let Ok(v) = std::env::var("GROQ_API_KEY") {
                if !v.trim().is_empty() {
                    eprintln!("[VoiceFlow] loaded GROQ_API_KEY from {}", path.display());
                    return v;
                }
            }
        }
    }

    String::new()
}

/// Resolve the Whisper model file.
///
/// Candidates are checked in order; the first existing file wins.
/// Bundled layouts (release builds):
///   macOS:   VoiceFlow.app/Contents/Resources/models/ggml-base.bin
///   Windows: models/ggml-base.bin (NSIS/MSI install dir)
///   Linux:   ../share/voiceflow/models/ggml-base.bin (AppImage/deb)
/// Dev layouts (binary in src-tauri/target/{debug,release}):
///   src-tauri/models/ggml-base.bin via ../../models/ggml-base.bin
/// Works on macOS, Windows, and Linux.
fn default_model_path() -> PathBuf {
    if let Ok(exe) = current_exe() {
        if let Some(dir) = exe.parent() {
            for cand in [
                // Windows NSIS/MSI install dir and Linux AppImage/deb install dir
                dir.join("models/ggml-base.bin"),
                // macOS bundled .app layout: Contents/Resources/models/ggml-base.bin
                dir.join("../Resources/models/ggml-base.bin"),
                // Windows NSIS installer layout (models next to the parent dir)
                dir.join("../models/ggml-base.bin"),
                // Linux AppImage layout: ../share/voiceflow/models/ggml-base.bin
                dir.join("../share/voiceflow/models/ggml-base.bin"),
                // Dev mode: binary at src-tauri/target/debug,
                // .. -> target, ../.. -> src-tauri, then models/:
                //   src-tauri/models/ggml-base.bin
                dir.join("../../models/ggml-base.bin"),
                // Alt dev layout: models/ at the repo/project root
                dir.join("../../../models/ggml-base.bin"),
            ] {
                if cand.exists() {
                    eprintln!("[VoiceFlow] using Whisper model: {}", cand.display());
                    return cand;
                }
            }
        }
    }
    // Final fallback: relative to the current working directory.
    PathBuf::from("models/ggml-base.bin")
}

#[tauri::command]
fn toggle_recording(state: tauri::State<AppState>) -> Result<String, String> {
    state.toggle()
}

#[tauri::command]
fn get_config(state: tauri::State<AppState>) -> Result<Config, String> {
    Ok(state.config.lock().unwrap().clone())
}

/// Persist the config as JSON in the OS app-config dir
/// (~/Library/Application Support on macOS, %APPDATA% on Windows).
fn config_file(app: &tauri::AppHandle) -> Option<PathBuf> {
    app.path()
        .app_config_dir()
        .ok()
        .map(|dir| dir.join("config.json"))
}

/// Read the whole config.json as a JSON object. Returns `serde_json::Value::Null`
/// if the file is missing or unreadable. The file layout is:
///   { "config": {...Config}, "whisperflow": {...WhisperFlowConfig} }
fn read_config_json(app: &tauri::AppHandle) -> serde_json::Value {
    if let Some(path) = config_file(app) {
        if let Ok(text) = std::fs::read_to_string(&path) {
            if let Ok(v) = serde_json::from_str::<serde_json::Value>(&text) {
                return v;
            }
        }
    }
    serde_json::Value::Null
}

/// Atomically replace a section of config.json while preserving the others.
fn patch_config_json(app: &tauri::AppHandle, section: &str, value: &serde_json::Value) {
    let mut root = read_config_json(app);
    if !root.is_object() {
        root = serde_json::json!({});
    }
    root[section] = value.clone();
    if let Some(path) = config_file(app) {
        if let Some(dir) = path.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        if let Ok(json) = serde_json::to_string_pretty(&root) {
            let _ = std::fs::write(&path, json);
        }
    }
}

fn load_config(app: &tauri::AppHandle) -> Config {
    read_config_json(app)
        .get("config")
        .and_then(|c| serde_json::from_value::<Config>(c.clone()).ok())
        .unwrap_or_else(Config::default)
}

fn save_config(app: &tauri::AppHandle, cfg: &Config) {
    let v = serde_json::to_value(cfg).unwrap_or(serde_json::Value::Null);
    patch_config_json(app, "config", &v);
}

fn load_whisperflow_config(app: &tauri::AppHandle) -> WhisperFlowConfig {
    read_config_json(app)
        .get("whisperflow")
        .and_then(|c| serde_json::from_value::<WhisperFlowConfig>(c.clone()).ok())
        .unwrap_or_else(WhisperFlowConfig::default)
}

fn save_whisperflow_config(app: &tauri::AppHandle, cfg: &WhisperFlowConfig) {
    let v = serde_json::to_value(cfg).unwrap_or(serde_json::Value::Null);
    patch_config_json(app, "whisperflow", &v);
}

#[tauri::command]
fn update_config(
    app: tauri::AppHandle,
    state: tauri::State<AppState>,
    cfg: Config,
) -> Result<(), String> {
    *state.config.lock().unwrap() = cfg.clone();
    save_config(&app, &cfg);
    Ok(())
}

// ---------------------------------------------------------------------------
// WhisperFlow streaming commands
// ---------------------------------------------------------------------------

#[tauri::command]
async fn start_streaming(
    app: tauri::AppHandle,
    wf_state: tauri::State<'_, WhisperFlowState>,
) -> Result<String, String> {
    let config = wf_state.config.lock().unwrap().clone();

    if config.api_key.is_empty() {
        return Err("No Groq API key configured. Set GROQ_API_KEY in Settings.".into());
    }

    let sender = whisperflow::start_engine(config, app);

    // Store the sender so we can send audio chunks to it
    *wf_state.sender.lock().unwrap() = Some(sender);

    Ok("Streaming engine started".into())
}

#[tauri::command]
async fn stop_streaming(
    wf_state: tauri::State<'_, WhisperFlowState>,
) -> Result<String, String> {
    // Clone sender out of the lock before awaiting
    let sender_opt = wf_state.sender.lock().unwrap().take();
    if let Some(sender) = sender_opt {
        let _ = sender.send(whisperflow::AudioMessage::Shutdown).await;
        Ok("Streaming engine stopped".into())
    } else {
        Ok("Streaming engine was not running".into())
    }
}

#[tauri::command]
async fn send_audio_chunk(
    wf_state: tauri::State<'_, WhisperFlowState>,
    samples: Vec<f32>,
) -> Result<(), String> {
    // Clone sender out of the lock before awaiting
    let sender_opt = wf_state.sender.lock().unwrap().clone();
    if let Some(sender) = sender_opt {
        sender
            .send(whisperflow::AudioMessage::Chunk(samples))
            .await
            .map_err(|e| format!("Failed to send audio: {e}"))
    } else {
        Err("Streaming engine not running".into())
    }
}

#[tauri::command]
fn edit_transcript(
    wf_state: tauri::State<'_, WhisperFlowState>,
    text: String,
) -> Result<String, String> {
    let config = wf_state.editor_config.lock().unwrap().clone();
    Ok(editor::edit_transcript(&text, &config))
}

#[tauri::command]
fn get_whisperflow_config(
    wf_state: tauri::State<'_, WhisperFlowState>,
) -> Result<WhisperFlowConfig, String> {
    Ok(wf_state.config.lock().unwrap().clone())
}

#[tauri::command]
fn update_whisperflow_config(
    app: tauri::AppHandle,
    wf_state: tauri::State<'_, WhisperFlowState>,
    config: WhisperFlowConfig,
) -> Result<(), String> {
    *wf_state.config.lock().unwrap() = config.clone();
    save_whisperflow_config(&app, &config);
    Ok(())
}

#[tauri::command]
fn get_editor_config(
    wf_state: tauri::State<'_, WhisperFlowState>,
) -> Result<EditorConfig, String> {
    Ok(wf_state.editor_config.lock().unwrap().clone())
}

#[tauri::command]
fn update_editor_config(
    wf_state: tauri::State<'_, WhisperFlowState>,
    config: EditorConfig,
) -> Result<(), String> {
    *wf_state.editor_config.lock().unwrap() = config;
    Ok(())
}

fn build_tray(app: &tauri::App) -> tauri::Result<()> {
    // Use CmdOrCtrl for cross-platform shortcuts (⌘ on macOS, Ctrl on Windows/Linux)
    let show = MenuItem::with_id(app, "show", "Show VoiceFlow", true, None::<&str>)?;
    let toggle = MenuItem::with_id(app, "toggle", "Start / Stop Recording", true, Some("CmdOrCtrl+Shift+V"))?;
    let separator1 = PredefinedMenuItem::separator(app)?;
    let stream = MenuItem::with_id(app, "stream", "Toggle Streaming (Groq)", true, Some("CmdOrCtrl+Shift+S"))?;
    let separator2 = PredefinedMenuItem::separator(app)?;
    let quit = MenuItem::with_id(app, "quit", "Quit VoiceFlow", true, None::<&str>)?;
    let menu = Menu::with_items(app, &[&show, &toggle, &separator1, &stream, &separator2, &quit])?;
    let icon =
        Image::from_bytes(include_bytes!("../icons/tray.png")).expect("failed to load tray icon");
    TrayIconBuilder::with_id("voiceflow-tray")
        .icon(icon)
        .menu(&menu)
        .show_menu_on_left_click(true)
        .on_menu_event(|app, event| match event.id().as_ref() {
            "show" => {
                if let Some(w) = app.get_webview_window("main") {
                    let _ = w.show();
                    let _ = w.set_focus();
                }
            }
            "toggle" => {
                if let Some(s) = app.try_state::<AppState>() {
                    let _ = s.toggle();
                }
            }
            "stream" => {
                // Emit event so frontend can toggle streaming mode
                let _ = app.emit("toggle-streaming", ());
            }
            "quit" => app.exit(0),
            _ => {}
        })
        .build(app)?;
    Ok(())
}

fn main() {
    tauri::Builder::default()
        .plugin(
            tauri_plugin_global_shortcut::Builder::new()
                .with_handler(|app, _sc, _event| {
                    // CmdOrCtrl+Shift+V toggles recording on any platform
                    if let Some(s) = app.try_state::<AppState>() {
                        let _ = s.toggle();
                    }
                })
                .build(),
        )
        .setup(|app| {
            // Load the Groq API key with robust precedence: process env ->
            // dotenv from CWD -> candidate .env paths -> known project root.
            let env_api_key = resolve_groq_api_key();

            let persisted = load_config(app.handle());
            app.manage(AppState::with_config(app.handle().clone(), persisted));

            // Initialize WhisperFlow streaming state. A non-empty persisted
            // api_key (user-entered in Settings) OVERRIDES the env-resolved key;
            // otherwise fall back to the env var / .env value.
            let mut wf_config = load_whisperflow_config(app.handle());
            if wf_config.api_key.trim().is_empty() {
                wf_config.api_key = env_api_key;
            }
            app.manage(WhisperFlowState {
                sender: Mutex::new(None),
                config: Mutex::new(wf_config),
                editor_config: Mutex::new(EditorConfig::default()),
            });

            // Register global shortcut — CmdOrCtrl works on macOS AND Windows
            let _ = app.global_shortcut().register("CmdOrCtrl+Shift+V");
            build_tray(app)?;
            if let Some(w) = app.get_webview_window("main") {
                let _ = w.show();
            }
            Ok(())
        })
        .on_window_event(|window, event| {
            if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                // Hide to the system tray instead of quitting (works on all platforms)
                api.prevent_close();
                let _ = window.hide();
            }
        })
        .invoke_handler(tauri::generate_handler![
            toggle_recording,
            get_config,
            update_config,
            // WhisperFlow streaming commands
            start_streaming,
            stop_streaming,
            send_audio_chunk,
            edit_transcript,
            get_whisperflow_config,
            update_whisperflow_config,
            get_editor_config,
            update_editor_config,
        ])
        .run(tauri::generate_context!())
        .expect("error while running VoiceFlow");
}
