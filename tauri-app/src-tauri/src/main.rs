mod audio;
mod cleanup;
mod hardware;
mod input;
mod model;
mod speech;
mod state;

use audio::recorder::AudioRecorder;
use audio::vad::{VadDetector, VadEvent};
use hardware::profiler::HardwareProfiler;
use input::coordinator::{HotkeyAction, KeyEdge, ShortcutCoordinator};
use input::hotkey::{HotkeyManager, ShortcutState};
use input::paster::{frontmost_pid, Paster};
use model::manager::ModelManager;
use speech::{polish_transcript, WhisperEngine};
use state::{with_state, AppSettings, AppStatus};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tauri::image::Image;
use tauri::{
    menu::{Menu, MenuItem},
    tray::{TrayIcon, TrayIconBuilder},
    Emitter, Manager, WebviewUrl, WebviewWindowBuilder,
};

struct AppStateInternal {
    recorder: Option<AudioRecorder>,
    engine: Option<Arc<Mutex<WhisperEngine>>>,
    paster: Option<Paster>,
    hotkey_manager: Option<HotkeyManager>,
    tray: Option<TrayIcon>,
    coordinator: Arc<Mutex<ShortcutCoordinator>>,
    vad: Arc<Mutex<VadDetector>>,
    model_path: Option<PathBuf>,
    session: Arc<AtomicU64>,
    tap_token: Arc<AtomicU64>,
    hands_free: Arc<AtomicBool>,
    threads: i32,
    front_pid: Option<i32>,
    hotkey_error: Option<String>,
}

static APP_DATA: Mutex<Option<AppStateInternal>> = Mutex::new(None);

fn with_app_data<F, R>(f: F) -> R
where
    F: FnOnce(&mut AppStateInternal) -> R,
{
    let mut data = APP_DATA.lock().unwrap();
    if data.is_none() {
        let _ = data.insert(AppStateInternal {
            recorder: None,
            engine: None,
            paster: None,
            hotkey_manager: None,
            tray: None,
            coordinator: Arc::new(Mutex::new(ShortcutCoordinator::new())),
            vad: Arc::new(Mutex::new(VadDetector::new(Default::default()))),
            model_path: None,
            session: Arc::new(AtomicU64::new(1)),
            tap_token: Arc::new(AtomicU64::new(1)),
            hands_free: Arc::new(AtomicBool::new(false)),
            threads: 4,
            front_pid: None,
            hotkey_error: None,
        });
    }
    f(data.as_mut().unwrap())
}

fn emit_status(app: &tauri::AppHandle, status: AppStatus) {
    with_state(|s| {
        *s.status.lock().unwrap() = status.clone();
    });
    let _ = app.emit("status", &status);
}

fn emit_error(app: &tauri::AppHandle, message: impl Into<String>) {
    let message = message.into();
    log::warn!("{message}");
    let _ = app.emit("error", message);
    emit_status(app, AppStatus::Error);
}

fn prepare_overlay(app: &tauri::AppHandle) {
    if let Some(window) = app.get_webview_window("mic-overlay") {
        let _ = window.set_always_on_top(true);
        let _ = window.set_focusable(false);
    }
}

fn current_session() -> u64 {
    with_app_data(|d| d.session.load(Ordering::SeqCst))
}

fn apply_action(app: &tauri::AppHandle, action: HotkeyAction) {
    match action {
        HotkeyAction::StartPushToTalk => {
            if let Err(err) = start_capture(app, false) {
                with_app_data(|d| {
                    d.hands_free.store(false, Ordering::SeqCst);
                    d.coordinator.lock().unwrap().force_idle();
                });
                emit_error(app, err);
            }
        }
        HotkeyAction::StartHandsFree => {
            if let Err(err) = start_capture(app, true) {
                with_app_data(|d| {
                    d.hands_free.store(false, Ordering::SeqCst);
                    d.coordinator.lock().unwrap().force_idle();
                });
                emit_error(app, err);
            }
        }
        HotkeyAction::StopAndTranscribe => stop_capture(app, true),
        HotkeyAction::Cancel => stop_capture(app, false),
        HotkeyAction::None => {}
    }
}

fn on_hotkey(app: tauri::AppHandle, edge: KeyEdge) {
    let now = Instant::now();
    let (action, arm) = with_app_data(|d| {
        let mut coord = d.coordinator.lock().unwrap();
        let action = coord.on_edge(edge, now);
        let arm = if let Some(deadline) = coord.pending_deadline() {
            let token = d.tap_token.fetch_add(1, Ordering::SeqCst) + 1;
            Some((token, deadline))
        } else {
            d.tap_token.fetch_add(1, Ordering::SeqCst);
            None
        };
        drop(coord);
        (action, arm)
    });
    if let Some((token, deadline)) = arm {
        let app_timer = app.clone();
        tauri::async_runtime::spawn(async move {
            let wait = deadline.saturating_duration_since(Instant::now());
            tokio::time::sleep(wait).await;
            let current = with_app_data(|d| d.tap_token.load(Ordering::SeqCst));
            if current != token {
                return;
            }
            let action = with_app_data(|d| d.coordinator.lock().unwrap().on_tick(Instant::now()));
            apply_action(&app_timer, action);
        });
    }
    apply_action(&app, action);
}

fn on_escape(app: tauri::AppHandle) {
    let action = with_app_data(|d| d.coordinator.lock().unwrap().on_escape());
    apply_action(&app, action);
}

fn register_session_escape(app: &tauri::AppHandle) {
    with_app_data(|d| {
        let Some(hm) = d.hotkey_manager.as_mut() else {
            return;
        };
        if hm.escape_is_registered() {
            return;
        }
        if let Err(err) = hm.register_escape(app, move |handle, _, event| {
            if event.state == ShortcutState::Pressed {
                on_escape(handle.clone());
            }
        }) {
            log::warn!("Escape hotkey failed: {err}");
        }
    });
}

fn start_capture(app: &tauri::AppHandle, hands_free: bool) -> Result<(), String> {
    let pid = frontmost_pid();
    prepare_overlay(app);
    let timeout_ms = with_state(|s| s.settings.lock().unwrap().silence_timeout_ms);

    let already = with_app_data(|d| {
        d.recorder
            .as_ref()
            .map(|r| r.is_recording())
            .unwrap_or(false)
    });
    if already {
        with_app_data(|d| {
            d.hands_free.store(hands_free, Ordering::SeqCst);
            d.front_pid = pid.or(d.front_pid);
        });
        emit_status(
            app,
            if hands_free {
                AppStatus::HandsFree
            } else {
                AppStatus::Recording
            },
        );
        return Ok(());
    }

    let app_cb = app.clone();
    with_app_data(|d| {
        d.session.fetch_add(1, Ordering::SeqCst);
        d.hands_free.store(hands_free, Ordering::SeqCst);
        d.front_pid = pid;
        {
            let mut vad = d.vad.lock().unwrap();
            vad.reset();
            vad.set_silence_timeout_ms(timeout_ms);
        }

        let mut recorder = AudioRecorder::new().map_err(|e| e.to_string())?;
        let vad = Arc::clone(&d.vad);
        let hands = Arc::clone(&d.hands_free);
        let app_level = app_cb.clone();
        let app_vad = app_cb.clone();

        recorder.set_chunk_callback(Arc::new(move |chunk: &[f32]| {
            if chunk.is_empty() {
                return;
            }
            let sum_sq: f32 = chunk.iter().map(|s| s * s).sum();
            let rms = (sum_sq / chunk.len() as f32).sqrt();
            let _ = app_level.emit("audio_level", (rms * 3.5).min(1.0));

            let event = vad.lock().unwrap().process_frame(chunk);
            let Some(event) = event else {
                return;
            };
            match &event {
                VadEvent::SilenceCountdown {
                    remaining_ms,
                    progress,
                } if hands.load(Ordering::SeqCst) => {
                    let _ = app_vad.emit(
                        "vad_countdown",
                        serde_json::json!({
                            "remaining_ms": remaining_ms,
                            "progress": progress,
                            "active": true
                        }),
                    );
                }
                VadEvent::SpeechStarted | VadEvent::Speaking { .. } => {
                    let _ = app_vad.emit(
                        "vad_countdown",
                        serde_json::json!({
                            "remaining_ms": 0,
                            "progress": 0.0,
                            "active": false
                        }),
                    );
                }
                VadEvent::ConfirmedSilence { .. } if hands.load(Ordering::SeqCst) => {
                    let app_stop = app_vad.clone();
                    tauri::async_runtime::spawn(async move {
                        let action =
                            with_app_data(|d| d.coordinator.lock().unwrap().on_silence_stop());
                        apply_action(&app_stop, action);
                    });
                }
                VadEvent::InitialTimeout if hands.load(Ordering::SeqCst) => {
                    let app_stop = app_vad.clone();
                    tauri::async_runtime::spawn(async move {
                        let action =
                            with_app_data(|d| d.coordinator.lock().unwrap().on_silence_cancel());
                        apply_action(&app_stop, action);
                    });
                }
                _ => {}
            }
        }));

        recorder
            .start_recording(None)
            .map_err(|e| format!("Microphone unavailable: {e}"))?;
        d.recorder = Some(recorder);
        Ok::<(), String>(())
    })?;

    register_session_escape(app);
    emit_status(
        app,
        if hands_free {
            AppStatus::HandsFree
        } else {
            AppStatus::Recording
        },
    );
    let _ = app.emit(
        "vad_countdown",
        serde_json::json!({"remaining_ms": 0, "progress": 0.0, "active": false}),
    );
    Ok(())
}

fn stop_capture(app: &tauri::AppHandle, transcribe: bool) {
    let timeout_language = with_state(|s| {
        let settings = s.settings.lock().unwrap();
        (settings.auto_paste, settings.language.clone())
    });

    let (samples, session_id, engine, threads, pid, auto_paste, language) = with_app_data(|d| {
        d.hands_free.store(false, Ordering::SeqCst);
        if let Some(hm) = d.hotkey_manager.as_mut() {
            hm.unregister_escape(app);
        }
        d.vad.lock().unwrap().reset();
        let samples = if d
            .recorder
            .as_ref()
            .map(|r| r.is_recording())
            .unwrap_or(false)
        {
            d.recorder.as_mut().unwrap().stop_recording()
        } else {
            Vec::new()
        };
        if !transcribe {
            d.session.fetch_add(1, Ordering::SeqCst);
            d.coordinator.lock().unwrap().force_idle();
        }
        let session_id = d.session.load(Ordering::SeqCst);
        (
            samples,
            session_id,
            d.engine.clone(),
            d.threads,
            d.front_pid,
            timeout_language.0,
            timeout_language.1,
        )
    });

    if !transcribe || samples.len() < 4_800 {
        with_app_data(|d| d.coordinator.lock().unwrap().force_idle());
        emit_status(app, AppStatus::Idle);
        return;
    }

    let Some(engine) = engine else {
        with_app_data(|d| d.coordinator.lock().unwrap().force_idle());
        emit_error(app, "Speech model is not ready yet. It is still loading.");
        let app_idle = app.clone();
        let session_id = session_id;
        tauri::async_runtime::spawn(async move {
            tokio::time::sleep(Duration::from_secs(2)).await;
            if current_session() == session_id {
                emit_status(&app_idle, AppStatus::Idle);
            }
        });
        return;
    };

    emit_status(app, AppStatus::Transcribing);
    let app_job = app.clone();
    tauri::async_runtime::spawn(async move {
        let work = tokio::task::spawn_blocking(move || {
            let guard = engine.lock().unwrap();
            guard
                .transcribe(&samples, threads, &language)
                .map_err(|err| err.to_string())
        });
        let outcome = match tokio::time::timeout(Duration::from_secs(45), work).await {
            Ok(Ok(result)) => result,
            Ok(Err(err)) => Err(format!("Transcription task failed: {err}")),
            Err(_) => Err("Transcription took too long and was stopped.".into()),
        };

        if current_session() != session_id {
            return;
        }

        match outcome {
            Ok(text) => {
                let polished = polish_transcript(&text);
                if polished.trim().is_empty() {
                    emit_status(&app_job, AppStatus::Idle);
                } else {
                    let _ = app_job.emit("transcript", polished.clone());
                    let mut hold = Duration::from_millis(900);
                    if auto_paste {
                        let mut paster = with_app_data(|d| d.paster.take());
                        let paste_result = match paster.as_mut() {
                            Some(paster) => paster.paste_text_for(&polished, pid),
                            None => Paster::new()
                                .and_then(|mut paster| paster.paste_text_for(&polished, pid)),
                        };
                        if let Some(paster) = paster {
                            with_app_data(|d| d.paster = Some(paster));
                        }
                        if current_session() != session_id {
                            return;
                        }
                        match paste_result {
                            Ok(()) => emit_status(&app_job, AppStatus::Success),
                            Err(err) => {
                                emit_error(&app_job, err.to_string());
                                hold = Duration::from_secs(4);
                            }
                        }
                    } else {
                        emit_status(&app_job, AppStatus::Success);
                    }
                    if current_session() == session_id {
                        with_app_data(|d| d.coordinator.lock().unwrap().force_idle());
                    }
                    tokio::time::sleep(hold).await;
                    if current_session() == session_id {
                        emit_status(&app_job, AppStatus::Idle);
                    }
                    return;
                }
            }
            Err(err) => {
                emit_error(&app_job, err);
                if current_session() == session_id {
                    with_app_data(|d| d.coordinator.lock().unwrap().force_idle());
                }
                tokio::time::sleep(Duration::from_secs(4)).await;
                if current_session() == session_id {
                    emit_status(&app_job, AppStatus::Idle);
                }
                return;
            }
        }

        if current_session() == session_id {
            with_app_data(|d| d.coordinator.lock().unwrap().force_idle());
        }
    });
}

fn queue_model_load(app: &tauri::AppHandle, path: PathBuf) {
    let app = app.clone();
    let remembered = path.clone();
    tauri::async_runtime::spawn(async move {
        let loaded = tokio::task::spawn_blocking(move || WhisperEngine::load(&path)).await;
        match loaded {
            Ok(Ok(engine)) => {
                log::info!("Whisper is ready ({})", remembered.display());
                with_app_data(|d| {
                    d.model_path = Some(remembered);
                    d.engine = Some(Arc::new(Mutex::new(engine)));
                });
            }
            Ok(Err(err)) => {
                log::error!("Whisper load failed: {err}");
                emit_error(&app, format!("Could not load the speech model: {err}"));
            }
            Err(err) => log::error!("Whisper load task failed: {err}"),
        }
    });
}

fn queue_recommended_download(app: &tauri::AppHandle, model_id: &str) {
    let filename = ModelManager::filename_for_model_id(model_id);
    let Some(info) = ModelManager::whisper_models()
        .into_iter()
        .find(|model| model.filename == filename)
    else {
        return;
    };
    if ModelManager::resolve_whisper_path(model_id)
        .map(|path| path.ends_with(&filename))
        .unwrap_or(false)
    {
        return;
    }
    let app = app.clone();
    let model_id = model_id.to_string();
    tauri::async_runtime::spawn(async move {
        let sha = info.sha256.clone();
        let progress_app = app.clone();
        let file_for_progress = info.filename.clone();
        match ModelManager::download_model(
            &info.url,
            &info.filename,
            sha.as_deref(),
            Some(move |progress| {
                let _ = progress_app.emit("model_download_progress", progress);
            }),
        )
        .await
        {
            Ok(path) => {
                let still_wanted = with_state(|s| s.settings.lock().unwrap().whisper_model == model_id);
                if still_wanted {
                    queue_model_load(&app, path);
                }
                let _ = file_for_progress;
            }
            Err(err) => {
                log::warn!("Recommended model download failed: {err}");
            }
        }
    });
}

#[tauri::command]
fn profile_hardware() -> hardware::profiler::HardwareProfile {
    HardwareProfiler::detect()
}

#[tauri::command]
async fn get_models() -> Vec<model::manager::ModelInfo> {
    ModelManager::check_models().await.unwrap_or_default()
}

#[tauri::command]
async fn download_model(
    app: tauri::AppHandle,
    url: String,
    filename: String,
    expected_sha256: Option<String>,
) -> Result<PathBuf, String> {
    let progress_app = app.clone();
    ModelManager::download_model(&url, &filename, expected_sha256.as_deref(), Some(move |progress| {
        let _ = progress_app.emit("model_download_progress", progress);
    }))
    .await
    .map_err(|err| err.to_string())
}

#[tauri::command]
fn toggle_recording(app: tauri::AppHandle) -> Result<String, String> {
    let recording = with_app_data(|d| {
        d.recorder
            .as_ref()
            .map(|r| r.is_recording())
            .unwrap_or(false)
    });
    if recording {
        stop_capture(&app, true);
        Ok("stopped".into())
    } else {
        start_capture(&app, false).map(|_| "recording".into())
    }
}

#[tauri::command]
fn start_hands_free(app: tauri::AppHandle) -> Result<String, String> {
    start_capture(&app, true).map(|_| "hands_free".into())
}

#[tauri::command]
fn cancel_recording(app: tauri::AppHandle) -> Result<String, String> {
    on_escape(app);
    Ok("cancelled".into())
}

#[tauri::command]
fn get_settings() -> AppSettings {
    with_state(|s| s.settings.lock().unwrap().clone())
}

#[tauri::command]
fn update_settings(app: tauri::AppHandle, settings: AppSettings) -> Result<(), String> {
    let old_show_mic_widget = with_state(|s| s.settings.lock().unwrap().show_mic_widget);
    let mut settings = settings;
    settings.silence_timeout_ms = settings.silence_timeout_ms.clamp(1_000, 5_000);
    if settings.cleanup_model != "off" {
        settings.cleanup_model = "off".into();
    }
    settings.save();
    with_state(|s| *s.settings.lock().unwrap() = settings.clone());
    with_app_data(|d| {
        d.vad
            .lock()
            .unwrap()
            .set_silence_timeout_ms(settings.silence_timeout_ms);
        d.coordinator
            .lock()
            .unwrap()
            .set_double_tap_enabled(settings.double_click_enabled);
    });

    if old_show_mic_widget != settings.show_mic_widget {
        if let Some(window) = app.get_webview_window("mic-overlay") {
            if settings.show_mic_widget {
                let _ = window.show();
            } else {
                let _ = window.hide();
            }
        }
    }
    let _ = app.emit("settings_changed", &settings);

    if let Some(path) = ModelManager::resolve_whisper_path(&settings.whisper_model) {
        let already = with_app_data(|d| d.model_path.clone());
        if already.as_ref() != Some(&path) {
            queue_model_load(&app, path);
        }
    } else {
        queue_recommended_download(&app, &settings.whisper_model);
    }
    Ok(())
}

#[tauri::command]
fn get_status() -> AppStatus {
    with_state(|s| s.status.lock().unwrap().clone())
}

#[tauri::command]
fn list_microphones() -> Result<Vec<String>, String> {
    AudioRecorder::new()
        .map_err(|e| e.to_string())?
        .list_devices()
        .map_err(|e| e.to_string())
}

#[tauri::command]
fn show_main_window(app: tauri::AppHandle) -> Result<(), String> {
    if let Some(window) = app.get_webview_window("main") {
        window.show().map_err(|e| e.to_string())?;
        window.set_focus().map_err(|e| e.to_string())?;
    } else {
        let window = WebviewWindowBuilder::new(&app, "main", WebviewUrl::App("index.html".into()))
            .title("VoiceFlow")
            .inner_size(820.0, 580.0)
            .min_inner_size(760.0, 500.0)
            .resizable(true)
            .center()
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
        show_main_window(app)?;
    }
    Ok(())
}

fn setup_tray(app: &tauri::AppHandle) -> Result<(), Box<dyn std::error::Error>> {
    let settings_item = MenuItem::with_id(app, "settings", "Settings", true, None::<&str>)?;
    let quit_item = MenuItem::with_id(app, "quit", "Quit VoiceFlow", true, None::<&str>)?;
    let menu = Menu::with_items(app, &[&settings_item, &quit_item])?;
    let icon = app.default_window_icon().cloned().or_else(|| {
        let mut rgba = Vec::with_capacity(16 * 16 * 4);
        for _ in 0..(16 * 16) {
            rgba.extend_from_slice(&[50, 200, 240, 255]);
        }
        Some(Image::new_owned(rgba, 16, 16))
    });
    let Some(icon) = icon else {
        return Ok(());
    };
    let tray = TrayIconBuilder::new()
        .menu(&menu)
        .icon(icon)
        .on_menu_event(|app, event| match event.id.as_ref() {
            "settings" => {
                let _ = show_main_window(app.clone());
            }
            "quit" => app.exit(0),
            _ => {}
        })
        .build(app)?;
    with_app_data(|d| d.tray = Some(tray));
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
        .setup(|app| {
            let profile = HardwareProfiler::detect();
            log::info!(
                "Hardware: {} {} MB → {}",
                profile.cpu_brand,
                profile.total_ram_mb,
                profile.recommended_whisper_model
            );

            let saved = state::has_saved_settings();
            let mut settings = AppSettings::load();
            if !saved {
                settings.whisper_model = profile.recommended_model_id.clone();
                settings.cleanup_model = "off".into();
                settings.save();
            }
            with_state(|s| *s.settings.lock().unwrap() = settings.clone());
            with_app_data(|d| {
                d.threads = ((profile.cpu_cores as i32) / 2).clamp(2, 8);
                d.vad
                    .lock()
                    .unwrap()
                    .set_silence_timeout_ms(settings.silence_timeout_ms);
                d.coordinator
                    .lock()
                    .unwrap()
                    .set_double_tap_enabled(settings.double_click_enabled);
                if let Ok(paster) = Paster::new() {
                    d.paster = Some(paster);
                }
            });

            if let Some(path) = ModelManager::resolve_whisper_path(&settings.whisper_model) {
                queue_model_load(app.handle(), path);
            } else {
                let app_h = app.handle().clone();
                tauri::async_runtime::spawn(async move {
                    tokio::time::sleep(Duration::from_millis(600)).await;
                    emit_error(
                        &app_h,
                        "No speech model is installed. Open Settings and download one.",
                    );
                });
            }
            queue_recommended_download(app.handle(), &settings.whisper_model);

            prepare_overlay(app.handle());
            if !settings.show_mic_widget {
                if let Some(overlay) = app.get_webview_window("mic-overlay") {
                    let _ = overlay.hide();
                }
            }
            if let Err(err) = setup_tray(app.handle()) {
                log::error!("Tray setup failed: {err}");
            }

            let mut hm = HotkeyManager::new();
            let app_h = app.handle().clone();
            match hm.register(app.handle(), move |_app, _shortcut, event| {
                let edge = match event.state {
                    ShortcutState::Pressed => KeyEdge::Down,
                    ShortcutState::Released => KeyEdge::Up,
                };
                on_hotkey(app_h.clone(), edge);
            }) {
                Ok(()) => {}
                Err(err) => {
                    let message = format!(
                        "Option+Space could not be registered ({err}). Another app may be using it."
                    );
                    log::error!("{message}");
                    with_app_data(|d| d.hotkey_error = Some(message.clone()));
                    let app_err = app.handle().clone();
                    tauri::async_runtime::spawn(async move {
                        tokio::time::sleep(Duration::from_millis(800)).await;
                        emit_error(&app_err, message);
                    });
                }
            }
            with_app_data(|d| d.hotkey_manager = Some(hm));
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            toggle_recording,
            start_hands_free,
            cancel_recording,
            profile_hardware,
            get_models,
            download_model,
            get_settings,
            update_settings,
            get_status,
            list_microphones,
            show_main_window,
            hide_main_window,
            toggle_main_window,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
