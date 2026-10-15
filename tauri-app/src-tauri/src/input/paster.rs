use anyhow::{Context, Result};
use arboard::Clipboard;

/// Cross-platform clipboard paste helper
pub struct Paster {
    cb: Option<Clipboard>,
}

impl Paster {
    pub fn new() -> Result<Self> {
        Ok(Paster {
            cb: Some(Clipboard::new().context("Failed to initialize clipboard")?),
        })
    }

    /// Copy text to clipboard and simulate paste (Cmd+V / Ctrl+V)
    pub fn paste_text(&mut self, text: &str) -> Result<()> {
        let cb = self.cb.as_mut().context("Clipboard not available")?;

        // Set text to clipboard
        cb.set_text(text.to_string())
            .context("Failed to set clipboard text")?;
        log::debug!("Text copied to clipboard: {} chars", text.len());

        // Simulate paste keystroke based on platform
        #[cfg(target_os = "macos")]
        {
            use std::process::Command;
            // Use AppleScript to simulate Cmd+V
            // First try to paste into the frontmost app
            let result = Command::new("osascript")
                .args([
                    "-e",
                    "tell application \"System Events\" to keystroke \"v\" using command down",
                ])
                .output();

            match result {
                Ok(output) => {
                    if !output.status.success() {
                        let stderr = String::from_utf8_lossy(&output.stderr);
                        log::warn!("AppleScript paste command failed: {}", stderr);
                    } else {
                        log::debug!("AppleScript paste command executed successfully");
                    }
                }
                Err(e) => {
                    log::warn!("Failed to execute paste command: {}", e);
                }
            }
        }

        #[cfg(target_os = "windows")]
        {
            // On Windows, we could use SendKeys or similar
            // For now, just copy to clipboard - user can paste manually
            log::info!("On Windows, text copied to clipboard. Auto-paste requires additional setup.");
        }

        #[cfg(target_os = "linux")]
        {
            use std::process::Command;
            // Try xdotool for X11
            let _ = Command::new("xdotool")
                .args(["keydown", "ctrl"])
                .output();
            let _ = Command::new("xdotool")
                .args(["key", "v"])
                .output();
            let _ = Command::new("xdotool")
                .args(["keyup", "ctrl"])
                .output();
        }

        Ok(())
    }

    /// Get current clipboard text
    pub fn get_clipboard_text(&mut self) -> Result<String> {
        let cb = self.cb.as_mut().context("Clipboard not available")?;
        cb.get_text().context("Failed to get clipboard text")
    }
}