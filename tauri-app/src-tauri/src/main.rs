mod audio;
mod cleanup;
mod hardware;
mod input;
mod model;
mod overlay;
mod platform;
mod speech;
mod state;

use audio::levels::LevelMeter;
use audio::recorder::AudioRecorder;
use audio::vad::{VadDetector, VadEvent};
use hardware::profiler::HardwareProfiler;
use input::coordinator::{HotkeyAction, KeyEdge, ShortcutCoordinator};
use input::hotkey::{HotkeyManager, ShortcutState};
use input::paster::{frontmost_pid, next_target, Paster};
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
    Emitter, Manager, WebviewWindowBuilder,
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
    /// Last app that was frontmost and was not VoiceFlow. A pill click makes
    /// this process frontmost before capture starts, so the click itself is
    /// not a safe place to read the target.
    last_external_pid: Option<i32>,
    hotkey_error: Option<String>,
    /// Bumped so a queued Escape registration from a finished take cannot land late.
    escape_ticket: AtomicU64,
    /// Set while a take is being committed so a live pass does not start behind it.
    commit_gate: AtomicBool,
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
            last_external_pid: None,
            hotkey_error: None,
            escape_ticket: AtomicU64::new(0),
            commit_gate: AtomicBool::new(false),
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
    // One window can only live on one display. prepare styles every pill;
    // overlay::sync_overlays opens another pill for each extra display.
    overlay::prepare_all(app);
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

fn on_option_double_tap(app: &tauri::AppHandle) {
    let action = with_app_data(|d| d.coordinator.lock().unwrap().on_option_double_tap());
    apply_action(app, action);
}

fn register_session_escape(app: &tauri::AppHandle) {
    let app = app.clone();
    let ticket = with_app_data(|d| d.escape_ticket.fetch_add(1, Ordering::SeqCst) + 1);
    // Must not call global_shortcut() on this stack. See platform::defer_main.
    platform::defer_main(move || {
        let current = with_app_data(|d| d.escape_ticket.load(Ordering::SeqCst));
        if current != ticket {
            return;
        }
        with_app_data(|d| {
            let Some(hm) = d.hotkey_manager.as_mut() else {
                return;
            };
            if hm.escape_is_registered() {
                return;
            }
            if let Err(err) = hm.register_escape(&app, move |handle, _, event| {
                if event.state == ShortcutState::Pressed {
                    on_escape(handle.clone());
                }
            }) {
                log::warn!("Escape hotkey failed: {err}");
            }
        });
    });
}

fn unregister_session_escape(app: &tauri::AppHandle) {
    let app = app.clone();
    with_app_data(|d| {
        d.escape_ticket.fetch_add(1, Ordering::SeqCst);
    });
    platform::defer_main(move || {
        with_app_data(|d| {
            if let Some(hm) = d.hotkey_manager.as_mut() {
                hm.unregister_escape(&app);
            }
        });
    });
}

fn start_capture(app: &tauri::AppHandle, hands_free: bool) -> Result<(), String> {
    // Read the focused app before the overlay or this process can become frontmost.
    let pid = frontmost_pid();
    let timeout_ms = with_state(|s| s.settings.lock().unwrap().silence_timeout_ms);

    if let Some(message) = audio::permission::denial_message() {
        return Err(message);
    }

    let already = with_app_data(|d| {
        d.recorder
            .as_ref()
            .map(|r| r.is_recording())
            .unwrap_or(false)
    });
    if already {
        with_app_data(|d| {
            d.hands_free.store(hands_free, Ordering::SeqCst);
            let ours = std::process::id() as i32;
            d.front_pid = next_target(d.last_external_pid.or(d.front_pid), pid, ours);
            if let Some(target) = d.front_pid {
                d.last_external_pid = Some(target);
            }
            if hands_free {
                d.coordinator.lock().unwrap().ensure_button_session();
                // A push-to-talk take can close the detector without committing.
                // Hands-free has to see a fresh silence window.
                let mut vad = d.vad.lock().unwrap();
                vad.reset();
                vad.set_silence_timeout_ms(timeout_ms);
            }
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

    // The pill has to appear before the microphone opens. The hotkey callback
    // used to reach the overlay event only after a lock that never returned.
    emit_status(
        app,
        if hands_free {
            AppStatus::HandsFree
        } else {
            AppStatus::Recording
        },
    );
    prepare_overlay(app);
    if hands_free {
        with_app_data(|d| d.coordinator.lock().unwrap().ensure_button_session());
    }

    let preferred = with_state(|s| s.settings.lock().unwrap().microphone.clone());
    let device = match preferred
        .as_deref()
        .map(str::trim)
        .filter(|name| !name.is_empty())
    {
        Some(name) => match AudioRecorder::device_named(name) {
            Ok(device) => Some(device),
            Err(err) => {
                log::warn!("{err}; using the default microphone");
                None
            }
        },
        None => None,
    };

    let app_cb = app.clone();
    with_app_data(|d| {
        d.session.fetch_add(1, Ordering::SeqCst);
        d.commit_gate.store(false, Ordering::SeqCst);
        d.hands_free.store(hands_free, Ordering::SeqCst);
        let ours = std::process::id() as i32;
        d.front_pid = next_target(d.last_external_pid.or(d.front_pid), pid, ours);
        if let Some(target) = d.front_pid {
            d.last_external_pid = Some(target);
        }
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
        let level_meter = Arc::new(Mutex::new(LevelMeter::new()));

        recorder.set_chunk_callback(Arc::new(move |chunk: &[f32]| {
            if chunk.is_empty() {
                return;
            }
            let levels = level_meter.lock().unwrap().push(chunk);
            if let Some(levels) = levels {
                let _ = app_level.emit("audio_levels", levels);
            }

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
            .start_recording(device)
            .map_err(|e| format!("Microphone unavailable: {e}"))?;
        d.recorder = Some(recorder);
        Ok::<(), String>(())
    })?;

    register_session_escape(app);
    let session_id = current_session();
    spawn_live_transcript(app, session_id);
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
    unregister_session_escape(app);
    with_app_data(|d| d.commit_gate.store(true, Ordering::SeqCst));
    if transcribe {
        with_app_data(|d| d.coordinator.lock().unwrap().mark_busy());
    }
    let timeout_language = with_state(|s| {
        let settings = s.settings.lock().unwrap();
        (settings.auto_paste, settings.language.clone())
    });

    let (samples, session_id, engine, threads, pid, auto_paste, language, stopped_mic) =
        with_app_data(|d| {
        d.hands_free.store(false, Ordering::SeqCst);
        d.vad.lock().unwrap().reset();
        let stopped_mic = d
            .recorder
            .as_ref()
            .map(|r| r.is_recording())
            .unwrap_or(false);
        let samples = if stopped_mic {
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
            stopped_mic,
        )
    });

    // A pause and a click can both commit the same take. The second caller
    // finds the microphone already stopped and must not wipe the first result.
    if transcribe && !stopped_mic {
        return;
    }

    if !transcribe || samples.len() < 4_800 {
        with_app_data(|d| d.coordinator.lock().unwrap().force_idle());
        if transcribe {
            let _ = app.emit("overlay_notice", serde_json::json!({ "kind": "no_sound" }));
        }
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
                    let _ = app_job.emit(
                        "overlay_notice",
                        serde_json::json!({ "kind": "no_sound" }),
                    );
                    emit_status(&app_job, AppStatus::Idle);
                } else {
                    let _ = app_job.emit("transcript", polished.clone());
                    let mut hold = Duration::from_millis(1_200);
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
                                hold = Duration::from_secs(5);
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
        // A click has nothing to hold. Speak, pause, and the take inserts itself.
        match start_capture(&app, true) {
            Ok(()) => Ok("hands_free".into()),
            Err(err) => {
                with_app_data(|d| {
                    d.hands_free.store(false, Ordering::SeqCst);
                    d.coordinator.lock().unwrap().force_idle();
                });
                Err(err)
            }
        }
    }
}

#[tauri::command]
fn start_hands_free(app: tauri::AppHandle) -> Result<String, String> {
    start_capture(&app, true).map(|_| "hands_free".into())
}

#[tauri::command]
fn cancel_recording(app: tauri::AppHandle) -> Result<String, String> {
    // The pill can start a capture while the shortcut machine is still idle.
    // Escape used to no-op in that state, so the close button left the mic on
    // and transcription never ran.
    with_app_data(|d| {
        d.tap_token.fetch_add(1, Ordering::SeqCst);
        d.hands_free.store(false, Ordering::SeqCst);
        d.coordinator.lock().unwrap().cancel_session();
        // Invalidates an in-flight transcription, not only an open microphone.
        d.session.fetch_add(1, Ordering::SeqCst);
    });
    let recording = with_app_data(|d| {
        d.recorder
            .as_ref()
            .map(|r| r.is_recording())
            .unwrap_or(false)
    });
    if recording {
        stop_capture(&app, false);
    } else {
        emit_status(&app, AppStatus::Idle);
    }
    Ok("cancelled".into())
}

/// While the mic is open, turn the buffer into words so the Handy sheet is not blank.
fn spawn_live_transcript(app: &tauri::AppHandle, session_id: u64) {
    let app = app.clone();
    tauri::async_runtime::spawn(async move {
        let mut last_len = 0usize;
        let mut checks = 0u32;
        let mut warned = false;
        loop {
            tokio::time::sleep(Duration::from_millis(280)).await;
            if current_session() != session_id {
                return;
            }
            checks += 1;
            let language = with_state(|s| s.settings.lock().unwrap().language.clone());
            let (recording, samples, total, engine, threads, peak, busy) = with_app_data(|d| {
                let recording = d
                    .recorder
                    .as_ref()
                    .map(|recorder| recorder.is_recording())
                    .unwrap_or(false);
                let peak = d.recorder.as_ref().map(|recorder| recorder.peak()).unwrap_or(0.0);
                let total = d
                    .recorder
                    .as_ref()
                    .map(|recorder| recorder.captured_len())
                    .unwrap_or(0);
                // The last five seconds is enough for the sheet. The full take
                // is transcribed once, when the user pauses or releases the key.
                let samples = d
                    .recorder
                    .as_ref()
                    .map(|recorder| recorder.snapshot_tail(16_000 * 5))
                    .unwrap_or_default();
                (
                    recording,
                    samples,
                    total,
                    d.engine.clone(),
                    d.threads,
                    peak,
                    d.commit_gate.load(Ordering::SeqCst),
                )
            });
            if busy || !recording || current_session() != session_id {
                return;
            }
            // Exact zeros mean the stream is open and the samples are empty.
            // Keep recording so a late phrase still transcribes, but say why the
            // sheet is blank instead of pretending the meter is listening.
            if checks >= 8 && peak < 1.0e-4 && !warned {
                warned = true;
                let _ = app.emit(
                    "capture_warning",
                    "No microphone signal. Allow microphone access for VoiceFlow, or pick another input.",
                );
            }
            if peak >= 1.0e-4 && warned {
                warned = false;
                let _ = app.emit("capture_warning", "");
            }
            if total < 8_000 || total < last_len + 6_400 {
                continue;
            }
            let Some(engine) = engine else {
                continue;
            };
            // A final pass needs this lock. Skip the preview rather than make
            // the user wait through two full decodes.
            if engine.try_lock().is_err() {
                continue;
            }
            last_len = total;
            let window = samples;
            let lang = language.clone();
            let work = tokio::task::spawn_blocking(move || {
                let guard = match engine.try_lock() {
                    Ok(guard) => guard,
                    Err(_) => return String::new(),
                };
                guard
                    .transcribe_partial(&window, threads, &lang)
                    .map(|text| polish_transcript(&text))
                    .unwrap_or_default()
            });
            let text = match work.await {
                Ok(text) => text,
                Err(err) => {
                    log::warn!("Live transcript failed: {err}");
                    continue;
                }
            };
            if current_session() != session_id || text.trim().is_empty() {
                continue;
            }
            let still = with_app_data(|d| {
                d.recorder
                    .as_ref()
                    .map(|recorder| recorder.is_recording())
                    .unwrap_or(false)
            });
            if still {
                let _ = app.emit("partial_transcript", text);
            }
        }
    });
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
        overlay::sync_overlays(&app);
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
async fn list_microphones() -> Result<Vec<String>, String> {
    // CoreAudio can stall inside cpal while it asks every input device for
    // supported formats. That work used to run on the UI thread, so the
    // window stayed white until the call returned.
    let listed = tokio::task::spawn_blocking(|| {
        AudioRecorder::new()
            .map_err(|e| e.to_string())?
            .list_devices()
            .map_err(|e| e.to_string())
    });
    match tokio::time::timeout(Duration::from_secs(2), listed).await {
        Ok(Ok(names)) => names,
        Ok(Err(err)) => Err(format!("Could not list microphones: {err}")),
        Err(_) => {
            log::warn!("Listing microphones stalled; keeping the saved device");
            Ok(Vec::new())
        }
    }
}

#[tauri::command]
fn show_main_window(app: tauri::AppHandle) -> Result<(), String> {
    // The installed app used to be a menu-bar agent. Opening it then showed
    // only the small HUD, with no Dock icon and no way into settings.
    #[cfg(target_os = "macos")]
    {
        let _ = app.set_activation_policy(tauri::ActivationPolicy::Regular);
    }

    if let Some(window) = app.get_webview_window("main") {
        let _ = window.unminimize();
        window.show().map_err(|e| e.to_string())?;
        window.set_focus().map_err(|e| e.to_string())?;
        return Ok(());
    }

    // Recreate from the same config Tauri uses at startup. Building a fresh
    // webview during setup left this window blank on macOS.
    let config = app
        .config()
        .app
        .windows
        .iter()
        .find(|window| window.label == "main")
        .cloned()
        .ok_or_else(|| "Main window config is missing".to_string())?;
    let window = WebviewWindowBuilder::from_config(&app, &config)
        .map_err(|e| e.to_string())?
        .build()
        .map_err(|e| e.to_string())?;
    window.set_focus().map_err(|e| e.to_string())?;
    Ok(())
}

#[tauri::command]
fn window_control(window: tauri::WebviewWindow, action: String) -> Result<(), String> {
    match action.as_str() {
        "close" => window.hide().map_err(|err| err.to_string())?,
        "minimize" => window.minimize().map_err(|err| err.to_string())?,
        "zoom" => {
            if window.is_maximized().map_err(|err| err.to_string())? {
                window.unmaximize().map_err(|err| err.to_string())?;
            } else {
                window.maximize().map_err(|err| err.to_string())?;
            }
        }
        other => return Err(format!("Unknown window action: {other}")),
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
    let open_item = MenuItem::with_id(app, "open", "Open VoiceFlow", true, None::<&str>)?;
    let quit_item = MenuItem::with_id(app, "quit", "Quit VoiceFlow", true, None::<&str>)?;
    let menu = Menu::with_items(app, &[&open_item, &quit_item])?;
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
        .show_menu_on_left_click(false)
        .icon(icon)
        .on_menu_event(|app, event| match event.id.as_ref() {
            "open" | "settings" => {
                let _ = show_main_window(app.clone());
            }
            "quit" => app.exit(0),
            _ => {}
        })
        .on_tray_icon_event(|tray, event| {
            if let tauri::tray::TrayIconEvent::Click {
                button: tauri::tray::MouseButton::Left,
                button_state: tauri::tray::MouseButtonState::Up,
                ..
            } = event
            {
                let _ = show_main_window(tray.app_handle().clone());
            }
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
            input::paster::prompt_accessibility_if_needed();
            std::thread::spawn(|| {
                let ours = std::process::id() as i32;
                loop {
                    if let Some(pid) = frontmost_pid() {
                        if pid != ours {
                            with_app_data(|d| d.last_external_pid = Some(pid));
                        }
                    }
                    std::thread::sleep(Duration::from_millis(350));
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
            // The main window is declared in tauri.conf.json. Building it here
            // produced a blank white webview on macOS.

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
                        emit_error(&app_err, message.clone());
                        tokio::time::sleep(Duration::from_secs(6)).await;
                        let still_error = with_state(|s| {
                            matches!(*s.status.lock().unwrap(), AppStatus::Error)
                        });
                        if still_error {
                            emit_status(&app_err, AppStatus::Idle);
                        }
                    });
                }
            }
            with_app_data(|d| d.hotkey_manager = Some(hm));

            if let Some(rx) = input::option_tap::start() {
                let app_tap = app.handle().clone();
                std::thread::Builder::new()
                    .name("voiceflow-option-dispatch".into())
                    .spawn(move || {
                        while rx.recv().is_ok() {
                            on_option_double_tap(&app_tap);
                        }
                    })
                    .ok();
            }
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
            window_control,
            overlay::save_overlay_position,
        ])
        .build(tauri::generate_context!())
        .expect("error while building tauri application")
        .run(|app, event| match event {
            // Dock click. The HUD counts as a visible window, so macOS will
            // not surface the main window on its own.
            tauri::RunEvent::Ready => {
                overlay::start_watch(app.clone());
                let _ = show_main_window(app.clone());
            }
            tauri::RunEvent::Reopen { .. } => {
                let _ = show_main_window(app.clone());
            }
            _ => {}
        });
}
