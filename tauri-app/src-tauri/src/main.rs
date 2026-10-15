mod audio;
mod cleanup;
mod input;
mod model;
mod speech;
mod state;

use state::{with_state, AppStatus};
use audio::recorder::AudioRecorder;
use speech::transcriber::{WhisperContext, WhisperParams};
use cleanup::cleaner::LlamaContext;
use model::manager::ModelManager;
use input::hotkey::HotkeyManager;
use input::paster::Paster;
use std::sync::Mutex;
use std::path::{Path, PathBuf};
use tauri::{async_runtime::spawn, Emitter, Manager, WebviewUrl, WebviewWindowBuilder, menu::{Menu, MenuItem}, tray::TrayIconBuilder};
use tauri::image::Image;

/// Application state holding long-lived objects
struct AppStateInternal {
    recorder: Option<AudioRecorder>,
    whisper: Option<WhisperContext>,
    cleaner: Option<LlamaContext>,
    paster: Option<Paster>,
    hotkey_manager: Option<HotkeyManager>,
    whisper_model_path: Option<PathBuf>,
    cleanup_model_path: Option<PathBuf>,
}

// Global state holder
static APP_DATA: Mutex<Option<AppStateInternal>> = Mutex::new(None);

fn with_app_data<F, R>(f: F) -> R
where
    F: FnOnce(&mut AppStateInternal) -> R,
{
    let mut data = APP_DATA.lock().unwrap();
    if data.is_none() {
        data.insert(AppStateInternal {
            recorder: None,
            whisper: None,
            cleaner: None,
            paster: None,
            hotkey_manager: None,
            whisper_model_path: None,
            cleanup_model_path: None,
        });
    }
    f(data.as_mut().unwrap())
}

// Tauri commands

#[tauri::command]
async fn get_models() -> Vec<model::manager::ModelInfo> {
    ModelManager::check_models().await.unwrap_or_default()
}

#[tauri::command]
async fn download_model(url: String, filename: String, expected_sha256: Option<String>) -> Result<PathBuf, String> {
    ModelManager::download_model(&url, &filename, expected_sha256.as_deref()).await
        .map_err(|e| e.to_string())
}

#[tauri::command]
fn toggle_recording(app: tauri::AppHandle) -> Result<String, String> {
    with_app_data(|data| {
        if data.recorder.as_ref().map(|r| r.is_recording()).unwrap_or(false) {
            // Stop recording
            let samples = data.recorder.as_mut().unwrap().stop_recording();

            // Transcribe in background thread
            let app_handle = app.clone();
            let whisper_path = data.whisper_model_path.clone();
            let cleanup_path = data.cleanup_model_path.clone();

            // Get auto_paste setting
            let auto_paste = with_state(|s| s.settings.lock().unwrap().auto_paste);

            // Emit status change to transcribing
            let _ = app.emit("status", AppStatus::Transcribing);

            spawn(async move {
                if let Some(path) = whisper_path {
                    match transcribe_audio(&samples, &path) {
                        Ok(text) => {
                            let cleaned = if !text.trim().is_empty() {
                                clean_text(&text, cleanup_path.as_ref()).unwrap_or(text.clone())
                            } else {
                                text
                            };

                            let _ = app_handle.emit("transcript", cleaned.clone());

                            // Auto-paste if enabled
                            if auto_paste {
                                // Try to create a paster and paste the text
                                match Paster::new() {
                                    Ok(mut paster) => {
                                        if let Err(e) = paster.paste_text(&cleaned) {
                                            log::warn!("Failed to paste text: {}", e);
                                        }
                                    }
                                    Err(e) => {
                                        log::warn!("Failed to create paster for auto-paste: {}", e);
                                    }
                                }
                            }
                        }
                        Err(e) => {
                            let _ = app_handle.emit("error", format!("Transcription failed: {}", e));
                        }
                    }
                } else {
                    let _ = app_handle.emit("error", "No whisper model found".to_string());
                }

                // Set status back to Idle and emit
                let _ = app_handle.emit("status", AppStatus::Idle);
            });

            Ok("stopped".to_string())
        } else {
            // Start recording
            let recorder = AudioRecorder::new().map_err(|e| e.to_string())?;
            recorder.start_recording(None).map_err(|e| e.to_string())?;
            data.recorder = Some(recorder);

            // Emit status change to recording
            let _ = app.emit("status", AppStatus::Recording);
            Ok("recording".to_string())
        }
    })
}

fn transcribe_audio(samples: &[f32], model_path: &Path) -> Result<String, String> {
    let mut whisper = WhisperContext::new(model_path)
        .map_err(|e| e.to_string())?;

    let params = WhisperParams::default();
    whisper.transcribe(samples, &params)
        .map_err(|e| e.to_string())
}

fn clean_text(text: &str, model_path: Option<&PathBuf>) -> Result<String, String> {
    match model_path {
        Some(path) if !path.as_path().to_string_lossy().is_empty() && path.exists() => {
            let mut cleaner = LlamaContext::new(path)
                .map_err(|e| format!("Failed to init cleanup model: {}", e))?;
            cleaner.clean_text(text, &cleanup::cleaner::CleanupParams::default())
                .map_err(|e| e.to_string())
        }
        _ => Ok(text.to_string()),
    }
}

#[tauri::command]
fn get_settings() -> state::AppSettings {
    with_state(|s| s.settings.lock().unwrap().clone())
}

#[tauri::command]
fn update_settings(settings: state::AppSettings) -> Result<(), String> {
    with_state(|s| {
        *s.settings.lock().map_err(|e| e.to_string())? = settings;
        Ok(())
    })
}

#[tauri::command]
fn get_status() -> AppStatus {
    with_state(|s| s.status.lock().unwrap().clone())
}

#[tauri::command]
fn list_microphones() -> Result<Vec<String>, String> {
    let recorder = AudioRecorder::new().map_err(|e| e.to_string())?;
    recorder.list_devices().map_err(|e| e.to_string())
}

#[tauri::command]
fn show_main_window(app: tauri::AppHandle) -> Result<(), String> {
    if let Some(window) = app.get_webview_window("main") {
        window.show().map_err(|e| e.to_string())?;
        window.set_focus().map_err(|e| e.to_string())?;
    } else {
        // Create main window if it doesn't exist
        let window = WebviewWindowBuilder::new(
            &app,
            "main",
            WebviewUrl::App("index.html".into())
        )
        .title("VoiceFlow")
        .inner_size(420.0, 560.0)
        .min_inner_size(380.0, 480.0)
        .resizable(true)
        .center()
        .decorations(true)
        .shadow(true)
        .skip_taskbar(true)
        .build()
        .map_err(|e| e.to_string())?;
        
        window.set_focus().map_err(|e| e.to_string())?;
    }
    Ok(())
}

#[tauri::command]
fn hide_main_window(app: tauri::AppHandle) -> Result<(), String> {
    if let Some(window) = app.get_webview_window("main") {
        window.hide().map_err(|e| e.to_string())?;
    }
    Ok(())
}

#[tauri::command]
fn toggle_main_window(app: tauri::AppHandle) -> Result<(), String> {
    if let Some(window) = app.get_webview_window("main") {
        if window.is_visible().unwrap_or(false) {
            window.hide().map_err(|e| e.to_string())?;
        } else {
            window.show().map_err(|e| e.to_string())?;
            window.set_focus().map_err(|e| e.to_string())?;
        }
    } else {
        // Create main window if it doesn't exist
        let window = WebviewWindowBuilder::new(
            &app,
            "main",
            WebviewUrl::App("index.html".into())
        )
        .title("VoiceFlow")
        .inner_size(420.0, 560.0)
        .min_inner_size(380.0, 480.0)
        .resizable(true)
        .center()
        .decorations(true)
        .shadow(true)
        .skip_taskbar(true)
        .build()
        .map_err(|e| e.to_string())?;
        
        window.set_focus().map_err(|e| e.to_string())?;
    }
    Ok(())
}


#[tauri::command]
fn create_main_window(app: tauri::AppHandle) -> Result<(), String> {
    use tauri::{WebviewUrl, WebviewWindowBuilder};
    
    let window = WebviewWindowBuilder::new(
        &app,
        "main",
        WebviewUrl::App("index.html".into())
    )
    .title("VoiceFlow")
    .inner_size(420.0, 560.0)
    .min_inner_size(380.0, 480.0)
    .resizable(true)
    .center()
    .decorations(true)
    .shadow(true)
    .skip_taskbar(true)
    .build()
    .map_err(|e| e.to_string())?;
    
    window.set_focus().map_err(|e| e.to_string())?;
    Ok(())
}

fn main() {
    env_logger::init();

    tauri::Builder::default()
        .plugin(tauri_plugin_global_shortcut::Builder::new().build())
        .plugin(tauri_plugin_fs::init())
        .plugin(tauri_plugin_shell::init())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_notification::init())
        .plugin(tauri_plugin_clipboard_manager::init())
        .plugin(tauri_plugin_os::init())
        .on_window_event(|_, event| {
            // Handle window focus events to ensure it appears when clicked from dock
            use tauri::WindowEvent;
            if let WindowEvent::Focused(is_focused) = event {
                if *is_focused {
                    // Window gained focus - could show or bring to front
                }
            }
        })
        .setup(|app| {
            // Try to locate models
            if let Ok(dir) = ModelManager::models_dir() {
                with_app_data(|data| {
                    // Look for available whisper models
                    let models = vec![
                        "ggml-tiny.bin",
                        "ggml-base.bin",
                        "ggml-small.bin",
                        "ggml-medium.en.bin",
                    ];
                    for model in models {
                        let path = dir.join(model);
                        if path.exists() {
                            data.whisper_model_path = Some(path);
                            break; // Use first available
                        }
                    }

                    // Check for cleanup model
                    let cleanup_path = dir.join("qwen3.5-0.8b-q4_k_m.gguf");
                    if cleanup_path.exists() {
                        data.cleanup_model_path = Some(cleanup_path);
                    }
                });
            }

            // Setup tray icon (menu bar)
            let app_handle = app.handle().clone();
            tauri::async_runtime::spawn(async move {
                if let Err(e) = setup_tray(&app_handle).await {
                    log::error!("Failed to setup tray: {}", e);
                }
            });

            // Initialize paster for clipboard operations
            if let Ok(paster) = Paster::new() {
                with_app_data(|data| {
                    data.paster = Some(paster);
                });
            }

            // Register global hotkey (Cmd+Space on macOS, Ctrl+Space on Windows/Linux) - works system-wide
            {
                let app_cloned = app.handle().clone();
                let mut hm = HotkeyManager::new();

                if let Ok(_) = hm.register(app.handle(), move |_, _, _| {
                    // Toggle recording on shortcut activation - works globally
                    let status = with_state(|s| s.status.lock().unwrap().clone());
                    if status == AppStatus::Idle {
                        // Emit event for frontend to handle (both main and overlay windows)
                        let _ = app_cloned.emit("hotkey_press", ());
                    }
                }) {
                    with_app_data(|data| {
                        data.hotkey_manager = Some(hm);
                    });
                }
            }

            // Ensure overlay window is visible and positioned correctly
            if let Some(overlay_window) = app.get_webview_window("mic-overlay") {
                // Window is already configured in tauri.conf.json to be visible on startup
                // Just ensure it's on top
                let _ = overlay_window.set_always_on_top(true);
                let _ = overlay_window.set_focus(); // Don't steal focus, just ensure visibility
            }

            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            toggle_recording,
            get_models,
            download_model,
            get_settings,
            update_settings,
            get_status,
            list_microphones,
            show_main_window,
            hide_main_window,
            toggle_main_window,
            create_main_window,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}

/// Setup system tray icon
async fn setup_tray(app: &tauri::AppHandle) -> Result<(), Box<dyn std::error::Error>> {
    use tauri::menu::{Menu, MenuItem};
    use tauri::tray::TrayIconBuilder;

    let quit_item = MenuItem::with_id(app, "quit", "Quit VoiceFlow", true, None::<&str>)?;
    let menu = Menu::with_items(app, &[&quit_item])?;

    // Try to load tray icon from bundled resources
    let tray_icon = app
        .path()
        .resolve("tray.png", tauri::path::BaseDirectory::Resource)
        .ok()
        .and_then(|f| {
            Image::from_path(&f).ok()
        })
        .or_else(|| {
            // Fallback: create a simple 16x16 RGBA image (blue pixel)
            let mut rgba = Vec::new();
            for _ in 0..(16 * 16) {
                rgba.push(0);
                rgba.push(0);
                rgba.push(0);
                rgba.push(255);
            }
            Image::from_bytes(&rgba).ok()
        });

    let tray = TrayIconBuilder::new()
        .menu(&menu)
        .icon(tray_icon.expect("Failed to create tray icon"))
        .build(app)?;

    Ok(())
}
