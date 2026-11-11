use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;
use std::time::Duration;

use once_cell::sync::Lazy;
use tauri::{Manager, PhysicalPosition, WebviewWindow, WebviewWindowBuilder};

const PILL_W: f64 = 440.0;
const PILL_H: f64 = 140.0;
const BOTTOM_INSET: f64 = 72.0;

#[derive(Debug, Clone, PartialEq)]
pub struct Screen {
    pub key: String,
    pub x: i32,
    pub y: i32,
    pub width: u32,
    pub height: u32,
    pub scale: f64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OverlayWindow {
    pub label: String,
    pub x: i32,
    pub y: i32,
    pub width: u32,
    pub height: u32,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Assignment {
    pub label: String,
    pub screen_key: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum OverlayOp {
    Keep { label: String },
    /// Move an existing window to this physical top-left.
    Place { label: String, x: i32, y: i32 },
    Create { label: String, x: i32, y: i32 },
    Close { label: String },
}

impl Screen {
    pub fn new(x: i32, y: i32, width: u32, height: u32, scale: f64) -> Self {
        Self {
            key: format!("{x},{y},{width},{height}"),
            x,
            y,
            width,
            height,
            scale,
        }
    }

    fn contains_point(&self, x: i32, y: i32) -> bool {
        let right = self.x.saturating_add(self.width as i32);
        let bottom = self.y.saturating_add(self.height as i32);
        x >= self.x && y >= self.y && x < right && y < bottom
    }

    fn contains_window(&self, window: &OverlayWindow) -> bool {
        let cx = window.x.saturating_add((window.width / 2) as i32);
        let cy = window.y.saturating_add((window.height / 2) as i32);
        self.contains_point(cx, cy)
    }
}

pub fn is_overlay_label(label: &str) -> bool {
    label == "mic-overlay" || label.starts_with("mic-overlay-")
}

/// Bottom-center of a display, in physical pixels. Matches the single-screen pill.
pub fn anchor(screen: &Screen) -> (i32, i32) {
    let scale = if screen.scale.is_finite() && screen.scale > 0.0 {
        screen.scale
    } else {
        1.0
    };
    let width = (PILL_W * scale).round() as i32;
    let height = (PILL_H * scale).round() as i32;
    let inset = (BOTTOM_INSET * scale).round() as i32;
    let x = screen.x + (screen.width as i32 - width) / 2;
    let y = screen.y + screen.height as i32 - inset - height;
    (x, y)
}

fn target_position(screen: &Screen, saved: &HashMap<String, (i32, i32)>) -> (i32, i32) {
    if let Some(&(x, y)) = saved.get(&screen.key) {
        let scale = if screen.scale.is_finite() && screen.scale > 0.0 {
            screen.scale
        } else {
            1.0
        };
        let width = (PILL_W * scale).round() as i32;
        let height = (PILL_H * scale).round() as i32;
        let cx = x.saturating_add(width / 2);
        let cy = y.saturating_add(height / 2);
        if screen.contains_point(cx, cy) {
            return (x, y);
        }
    }
    anchor(screen)
}

fn next_label(taken: &HashSet<String>) -> String {
    if !taken.contains("mic-overlay") {
        return "mic-overlay".to_string();
    }
    let mut n = 2u32;
    loop {
        let label = format!("mic-overlay-{n}");
        if !taken.contains(&label) {
            return label;
        }
        n += 1;
        if n > 32 {
            return format!("mic-overlay-extra-{n}");
        }
    }
}

/// One pill per connected display.
///
/// A window stays on the display it is assigned to. A display with no pill
/// gets one. Extra pills are closed. A pill that has not been settled yet is
/// moved to the bottom center (or the spot the user last dragged it to).
pub fn plan_overlays(
    screens: &[Screen],
    windows: &[OverlayWindow],
    assignments: &[Assignment],
    saved: &HashMap<String, (i32, i32)>,
) -> (Vec<OverlayOp>, Vec<Assignment>) {
    if screens.is_empty() {
        return (Vec::new(), assignments.to_vec());
    }

    let mut ops = Vec::new();
    let mut next_assignments = Vec::new();
    let mut used: HashSet<String> = HashSet::new();
    let mut taken_labels: HashSet<String> = windows.iter().map(|window| window.label.clone()).collect();

    for assignment in assignments {
        let Some(screen) = screens.iter().find(|screen| screen.key == assignment.screen_key) else {
            continue;
        };
        let Some(window) = windows.iter().find(|window| window.label == assignment.label) else {
            continue;
        };
        if !used.insert(window.label.clone()) {
            continue;
        }
        let (x, y) = target_position(screen, saved);
        if screen.contains_window(window) {
            ops.push(OverlayOp::Keep { label: window.label.clone() });
        } else {
            ops.push(OverlayOp::Place {
                label: window.label.clone(),
                x,
                y,
            });
        }
        next_assignments.push(assignment.clone());
    }

    for screen in screens {
        if next_assignments.iter().any(|assignment| assignment.screen_key == screen.key) {
            continue;
        }
        let (x, y) = target_position(screen, saved);
        let on_screen = windows
            .iter()
            .find(|window| !used.contains(&window.label) && screen.contains_window(window));
        // A pill already sitting on another display belongs to that display.
        // Only a window that is on none of them can be moved here.
        let homeless = windows.iter().find(|window| {
            !used.contains(&window.label)
                && screens.iter().all(|other| !other.contains_window(window))
        });
        if let Some(window) = on_screen.or(homeless) {
            used.insert(window.label.clone());
            ops.push(OverlayOp::Place {
                label: window.label.clone(),
                x,
                y,
            });
            next_assignments.push(Assignment {
                label: window.label.clone(),
                screen_key: screen.key.clone(),
            });
            continue;
        }
        let label = next_label(&taken_labels);
        taken_labels.insert(label.clone());
        ops.push(OverlayOp::Create {
            label: label.clone(),
            x,
            y,
        });
        next_assignments.push(Assignment {
            label,
            screen_key: screen.key.clone(),
        });
    }

    for window in windows {
        if !used.contains(&window.label) {
            ops.push(OverlayOp::Close {
                label: window.label.clone(),
            });
        }
    }

    (ops, next_assignments)
}

static ASSIGNMENTS: Lazy<Mutex<Vec<Assignment>>> = Lazy::new(|| Mutex::new(Vec::new()));
static SAVED: Lazy<Mutex<HashMap<String, (i32, i32)>>> = Lazy::new(|| Mutex::new(load_saved()));
static WATCH_STARTED: AtomicBool = AtomicBool::new(false);
static SYNC_QUEUED: AtomicBool = AtomicBool::new(false);

fn positions_file() -> Option<std::path::PathBuf> {
    let dir = match std::env::consts::OS {
        "macos" => dirs::home_dir()?.join("Library/Application Support/VoiceFlow"),
        "windows" => dirs::config_dir()?.join("VoiceFlow"),
        "linux" => dirs::data_dir()?.join("voiceflow"),
        _ => dirs::home_dir()?.join(".voiceflow"),
    };
    Some(dir.join("overlay-positions.json"))
}

fn load_saved() -> HashMap<String, (i32, i32)> {
    let Some(path) = positions_file() else {
        return HashMap::new();
    };
    let Ok(text) = std::fs::read_to_string(path) else {
        return HashMap::new();
    };
    let Ok(raw) = serde_json::from_str::<HashMap<String, serde_json::Value>>(&text) else {
        return HashMap::new();
    };
    raw.into_iter()
        .filter_map(|(key, value)| {
            let x = value.get("x")?.as_i64()? as i32;
            let y = value.get("y")?.as_i64()? as i32;
            Some((key, (x, y)))
        })
        .collect()
}

fn store_saved(saved: &HashMap<String, (i32, i32)>) {
    let Some(path) = positions_file() else {
        return;
    };
    if let Some(dir) = path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    let raw: HashMap<String, serde_json::Value> = saved
        .iter()
        .map(|(key, (x, y))| {
            (
                key.clone(),
                serde_json::json!({ "x": x, "y": y }),
            )
        })
        .collect();
    if let Ok(text) = serde_json::to_string(&raw) {
        let _ = std::fs::write(path, text);
    }
}

pub fn start_watch(app: tauri::AppHandle) {
    if WATCH_STARTED.swap(true, Ordering::SeqCst) {
        return;
    }
    sync_overlays(&app);
    let watched = app.clone();
    std::thread::Builder::new()
        .name("voiceflow-screens".into())
        .spawn(move || loop {
            std::thread::sleep(Duration::from_secs(2));
            request_sync(watched.clone());
        })
        .ok();
}

fn request_sync(app: tauri::AppHandle) {
    if SYNC_QUEUED.swap(true, Ordering::SeqCst) {
        return;
    }
    crate::platform::defer_main(move || {
        SYNC_QUEUED.store(false, Ordering::SeqCst);
        sync_overlays(&app);
    });
}

pub fn sync_overlays(app: &tauri::AppHandle) {
    let Ok(monitors) = app.available_monitors() else {
        return;
    };
    if monitors.is_empty() {
        return;
    }
    let mut screens: Vec<Screen> = monitors
        .iter()
        .map(|monitor| {
            let position = monitor.position();
            let size = monitor.size();
            Screen::new(
                position.x,
                position.y,
                size.width,
                size.height,
                monitor.scale_factor(),
            )
        })
        .collect();
    screens.sort_by(|a, b| (a.y, a.x).cmp(&(b.y, b.x)));

    let windows = snapshot_overlays(app);
    let saved = SAVED.lock().unwrap().clone();
    let previous = ASSIGNMENTS.lock().unwrap().clone();
    let (ops, next_assignments) = plan_overlays(&screens, &windows, &previous, &saved);
    *ASSIGNMENTS.lock().unwrap() = next_assignments;

    let show = crate::state::with_state(|state| state.settings.lock().unwrap().show_mic_widget);
    for op in ops {
        match op {
            OverlayOp::Keep { label } => {
                if let Some(window) = app.get_webview_window(&label) {
                    style_overlay(&window);
                    apply_visibility(&window, show);
                }
            }
            OverlayOp::Place { label, x, y } => {
                if let Some(window) = app.get_webview_window(&label) {
                    move_overlay(&window, x, y);
                    style_overlay(&window);
                    apply_visibility(&window, show);
                }
            }
            OverlayOp::Create { label, x, y } => {
                if let Err(err) = spawn_overlay(app, &label, x, y, show) {
                    log::warn!("Could not open the floating button on another display: {err}");
                    ASSIGNMENTS
                        .lock()
                        .unwrap()
                        .retain(|assignment| assignment.label != label);
                } else {
                    log::info!("Floating button opened on another display ({label})");
                }
            }
            OverlayOp::Close { label } => {
                if let Some(window) = app.get_webview_window(&label) {
                    let _ = window.close();
                }
            }
        }
    }
}

fn snapshot_overlays(app: &tauri::AppHandle) -> Vec<OverlayWindow> {
    let mut windows = Vec::new();
    for (label, window) in app.webview_windows() {
        if !is_overlay_label(&label) {
            continue;
        }
        let (x, y, width, height) = match (window.outer_position(), window.outer_size()) {
            (Ok(position), Ok(size)) => (position.x, position.y, size.width, size.height),
            _ => (i32::MIN / 4, i32::MIN / 4, 1, 1),
        };
        windows.push(OverlayWindow {
            label,
            x,
            y,
            width,
            height,
        });
    }
    windows
}

fn spawn_overlay(
    app: &tauri::AppHandle,
    label: &str,
    x: i32,
    y: i32,
    show: bool,
) -> Result<(), String> {
    let mut config = app
        .config()
        .app
        .windows
        .iter()
        .find(|window| window.label == "mic-overlay")
        .cloned()
        .ok_or_else(|| "Overlay window config is missing".to_string())?;
    config.label = label.to_string();
    config.focus = false;
    config.focusable = false;
    config.visible = show;
    config.always_on_top = true;
    config.visible_on_all_workspaces = true;
    config.skip_taskbar = true;
    let window = WebviewWindowBuilder::from_config(app, &config)
        .map_err(|err| err.to_string())?
        .build()
        .map_err(|err| err.to_string())?;
    style_overlay(&window);
    apply_visibility(&window, show);
    // macOS often ignores the first move onto another display until the window is shown.
    move_overlay(&window, x, y);
    Ok(())
}

fn move_overlay(window: &WebviewWindow, x: i32, y: i32) {
    let position = PhysicalPosition::new(x, y);
    let _ = window.set_position(position);
    let _ = window.set_position(position);
}

pub fn prepare_all(app: &tauri::AppHandle) {
    for (label, window) in app.webview_windows() {
        if is_overlay_label(&label) {
            style_overlay(&window);
        }
    }
}

fn style_overlay(window: &WebviewWindow) {
    let _ = window.set_always_on_top(true);
    let _ = window.set_focusable(false);
    let _ = window.set_ignore_cursor_events(false);
    let _ = window.set_visible_on_all_workspaces(true);
}

fn apply_visibility(window: &WebviewWindow, show: bool) {
    let visible = window.is_visible().unwrap_or(false);
    if show && !visible {
        let _ = window.show();
    } else if !show && visible {
        let _ = window.hide();
    }
}

#[tauri::command]
pub fn save_overlay_position(window: WebviewWindow, x: i32, y: i32) {
    let Ok(monitors) = window.available_monitors() else {
        return;
    };
    let size = window.outer_size().unwrap_or(tauri::PhysicalSize::new(440, 140));
    let cx = x.saturating_add((size.width / 2) as i32);
    let cy = y.saturating_add((size.height / 2) as i32);
    let Some(screen) = monitors.iter().find_map(|monitor| {
        let position = monitor.position();
        let bounds = monitor.size();
        let screen = Screen::new(
            position.x,
            position.y,
            bounds.width,
            bounds.height,
            monitor.scale_factor(),
        );
        screen.contains_point(cx, cy).then_some(screen)
    }) else {
        return;
    };
    let mut saved = SAVED.lock().unwrap();
    saved.insert(screen.key, (x, y));
    store_saved(&saved);
}

#[cfg(test)]
mod tests {
    use super::*;

    fn screens() -> Vec<Screen> {
        vec![
            Screen::new(0, 0, 1920, 1080, 2.0),
            Screen::new(-1512, 0, 1512, 982, 2.0),
        ]
    }

    fn window(label: &str, x: i32, y: i32) -> OverlayWindow {
        OverlayWindow {
            label: label.to_string(),
            x,
            y,
            width: 880,
            height: 280,
        }
    }

    #[test]
    fn a_second_display_gets_its_own_pill() {
        let screens = screens();
        let windows = vec![window("mic-overlay", 400, 700)];
        let (ops, assignments) = plan_overlays(&screens, &windows, &[], &HashMap::new());
        assert!(assignments.iter().any(|a| a.screen_key == screens[0].key));
        assert!(assignments.iter().any(|a| a.screen_key == screens[1].key));
        assert!(ops.iter().any(|op| matches!(op, OverlayOp::Create { .. })));
    }

    #[test]
    fn anchor_on_a_display_to_the_left_stays_on_that_display() {
        let screen = Screen::new(-1512, 0, 1512, 982, 2.0);
        let (x, y) = anchor(&screen);
        assert!(x < 0, "x {x} should sit on the left display");
        assert!(screen.contains_point(x + 10, y + 10));
    }

    #[test]
    fn settled_pills_stay_put_and_a_stray_one_is_sent_back() {
        let screens = screens();
        let left = &screens[1];
        let windows = vec![
            window("mic-overlay", 400, 700),
            window("mic-overlay-2", 100, 400),
        ];
        let assignments = vec![
            Assignment {
                label: "mic-overlay".into(),
                screen_key: screens[0].key.clone(),
            },
            Assignment {
                label: "mic-overlay-2".into(),
                screen_key: left.key.clone(),
            },
        ];
        let (ops, _) = plan_overlays(&screens, &windows, &assignments, &HashMap::new());
        assert!(ops.iter().any(|op| matches!(op, OverlayOp::Keep { label } if label == "mic-overlay")));
        assert!(ops.iter().any(|op| matches!(
            op,
            OverlayOp::Place { label, x, .. } if label == "mic-overlay-2" && *x < 0
        )));
    }

    #[test]
    fn an_extra_pill_on_one_display_is_closed_when_every_display_is_covered() {
        let screen = Screen::new(0, 0, 1920, 1080, 1.0);
        let windows = vec![window("mic-overlay", 100, 100), window("mic-overlay-2", 200, 100)];
        let assignments = vec![Assignment {
            label: "mic-overlay".into(),
            screen_key: screen.key.clone(),
        }];
        let (ops, next) = plan_overlays(&[screen], &windows, &assignments, &HashMap::new());
        assert_eq!(next.len(), 1);
        assert!(ops.iter().any(|op| matches!(op, OverlayOp::Close { label } if label == "mic-overlay-2")));
    }

    #[test]
    fn a_saved_drag_is_reused_for_that_display() {
        let screen = Screen::new(0, 0, 1920, 1080, 1.0);
        let mut saved = HashMap::new();
        saved.insert(screen.key.clone(), (320, 640));
        let (x, y) = target_position(&screen, &saved);
        assert_eq!((x, y), (320, 640));
    }
}
