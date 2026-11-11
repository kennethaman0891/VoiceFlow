use anyhow::Result;
use tauri_plugin_global_shortcut::{Code, GlobalShortcutExt, Modifiers, Shortcut, ShortcutEvent};

pub use tauri_plugin_global_shortcut::ShortcutState;

/// Manages global keyboard shortcuts for recording
pub struct HotkeyManager {
    main_shortcut: Option<Shortcut>,
    escape_shortcut: Option<Shortcut>,
}

impl HotkeyManager {
    pub fn new() -> Self {
        Self {
            main_shortcut: None,
            escape_shortcut: None,
        }
    }

    /// Register the main recording shortcut (Option+Space on macOS, Ctrl+Space on Windows/Linux)
    pub fn register(
        &mut self,
        app_handle: &tauri::AppHandle,
        handler: impl Fn(&tauri::AppHandle, &Shortcut, ShortcutEvent) + Send + Sync + 'static,
    ) -> Result<()> {
        // Option+Space on macOS (matches Handy to avoid Spotlight conflict), Ctrl+Space on Win/Linux
        #[cfg(target_os = "macos")]
        let modifiers = Some(Modifiers::ALT);
        #[cfg(not(target_os = "macos"))]
        let modifiers = Some(Modifiers::CONTROL);

        let shortcut = Shortcut::new(modifiers, Code::Space);

        app_handle
            .global_shortcut()
            .on_shortcut(shortcut.clone(), handler)?;

        self.main_shortcut = Some(shortcut);
        Ok(())
    }

    /// Register Escape key listener for quick cancellation
    pub fn register_escape(
        &mut self,
        app_handle: &tauri::AppHandle,
        handler: impl Fn(&tauri::AppHandle, &Shortcut, ShortcutEvent) + Send + Sync + 'static,
    ) -> Result<()> {
        let escape = Shortcut::new(None, Code::Escape);
        let _ = app_handle.global_shortcut().on_shortcut(escape.clone(), handler);
        self.escape_shortcut = Some(escape);
        Ok(())
    }

    pub fn unregister_escape(&mut self, app_handle: &tauri::AppHandle) {
        if let Some(escape) = self.escape_shortcut.take() {
            let _ = app_handle.global_shortcut().unregister(escape);
        }
    }

    pub fn escape_is_registered(&self) -> bool {
        self.escape_shortcut.is_some()
    }

    /// Unregister shortcuts
    pub fn unregister(&mut self, app_handle: &tauri::AppHandle) -> Result<()> {
        if let Some(ref shortcut) = self.main_shortcut {
            let _ = app_handle.global_shortcut().unregister(shortcut.clone());
        }
        if let Some(ref escape) = self.escape_shortcut {
            let _ = app_handle.global_shortcut().unregister(escape.clone());
        }
        Ok(())
    }
}

impl Default for HotkeyManager {
    fn default() -> Self {
        Self::new()
    }
}
