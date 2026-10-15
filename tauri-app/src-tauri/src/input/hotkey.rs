use anyhow::Result;
use tauri_plugin_global_shortcut::{GlobalShortcutExt, Modifiers, Shortcut, ShortcutEvent, Code};

/// Manages global keyboard shortcuts for recording
pub struct HotkeyManager {
    shortcut: Option<Shortcut>,
}

impl HotkeyManager {
    pub fn new() -> Self {
        Self { shortcut: None }
    }

    /// Register the main recording shortcut (Cmd+Space on macOS, Ctrl+Space on Windows/Linux)
    pub fn register(
        &mut self,
        app_handle: &tauri::AppHandle,
        handler: impl Fn(&tauri::AppHandle, &Shortcut, ShortcutEvent) + Send + Sync + 'static,
    ) -> Result<()> {
        // Use platform-appropriate modifier
        #[cfg(target_os = "macos")]
        let modifiers = Some(Modifiers::SUPER); // Command key
        #[cfg(not(target_os = "macos"))]
        let modifiers = Some(Modifiers::CONTROL); // Control key

        let shortcut = Shortcut::new(modifiers, Code::Space);

        app_handle
            .global_shortcut()
            .on_shortcut(shortcut, handler)?;

        self.shortcut = Some(shortcut);
        Ok(())
    }

    /// Unregister the hotkey
    pub fn unregister(&mut self, app_handle: &tauri::AppHandle) -> Result<()> {
        if let Some(ref shortcut) = self.shortcut {
            app_handle.global_shortcut().unregister(shortcut.clone())?;
        }
        Ok(())
    }
}

impl Default for HotkeyManager {
    fn default() -> Self {
        Self::new()
    }
}
