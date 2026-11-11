use anyhow::{Context, Result};
use arboard::Clipboard;
use std::thread::sleep;
use std::time::Duration;

/// Cross-platform clipboard paste helper with clipboard history preservation
pub struct Paster {
    cb: Option<Clipboard>,
}

impl Paster {
    pub fn new() -> Result<Self> {
        Ok(Paster {
            cb: Some(Clipboard::new().context("Failed to initialize clipboard")?),
        })
    }

    /// Copy text and paste it into the app that was focused when dictation started.
    pub fn paste_text(&mut self, text: &str) -> Result<()> {
        self.paste_text_for(text, None)
    }

    pub fn paste_text_for(&mut self, text: &str, reactivate_pid: Option<i32>) -> Result<()> {
        let cb = self.cb.as_mut().context("Clipboard not available")?;
        let previous_text = cb.get_text().ok();

        #[cfg(target_os = "macos")]
        {
            if !accessibility_trusted() {
                cb.set_text(text.to_string())
                    .context("Failed to set clipboard text")?;
                anyhow::bail!(
                    "Copied. Grant Accessibility to VoiceFlow in System Settings to paste automatically."
                );
            }
            if let Err(err) = write_transient_text(text) {
                log::warn!("Transient pasteboard write failed ({err}); using plain clipboard");
                cb.set_text(text.to_string())
                    .context("Failed to set clipboard text")?;
            }
            if let Some(pid) = reactivate_pid {
                if pid != std::process::id() as i32 {
                    activate_pid(pid);
                    sleep(Duration::from_millis(40));
                }
            }
        }
        #[cfg(not(target_os = "macos"))]
        {
            let _ = reactivate_pid;
            cb.set_text(text.to_string())
                .context("Failed to set clipboard text")?;
            sleep(Duration::from_millis(35));
        }

        Self::simulate_paste()?;
        sleep(Duration::from_millis(220));

        if let Some(prev) = previous_text {
            let _ = cb.set_text(prev);
        }
        Ok(())
    }

    #[cfg(target_os = "macos")]
    fn simulate_paste() -> Result<()> {
        use core_graphics::event::{CGEvent, CGEventFlags, CGEventTapLocation, CGKeyCode};
        use core_graphics::event_source::{CGEventSource, CGEventSourceStateID};

        let source = CGEventSource::new(CGEventSourceStateID::CombinedSessionState)
            .map_err(|_| anyhow::anyhow!("Failed to create CGEventSource"))?;

        let cmd_key: CGKeyCode = 0x37;
        let v_key: CGKeyCode = 0x09;

        let cmd_down = CGEvent::new_keyboard_event(source.clone(), cmd_key, true)
            .map_err(|_| anyhow::anyhow!("Failed to create Cmd down event"))?;
        let v_down = CGEvent::new_keyboard_event(source.clone(), v_key, true)
            .map_err(|_| anyhow::anyhow!("Failed to create V down event"))?;
        let v_up = CGEvent::new_keyboard_event(source.clone(), v_key, false)
            .map_err(|_| anyhow::anyhow!("Failed to create V up event"))?;
        let cmd_up = CGEvent::new_keyboard_event(source.clone(), cmd_key, false)
            .map_err(|_| anyhow::anyhow!("Failed to create Cmd up event"))?;

        cmd_down.set_flags(CGEventFlags::CGEventFlagCommand);
        v_down.set_flags(CGEventFlags::CGEventFlagCommand);
        v_up.set_flags(CGEventFlags::CGEventFlagCommand);

        cmd_down.post(CGEventTapLocation::HID);
        v_down.post(CGEventTapLocation::HID);
        v_up.post(CGEventTapLocation::HID);
        cmd_up.post(CGEventTapLocation::HID);

        Ok(())
    }

    #[cfg(target_os = "windows")]
    fn simulate_paste() -> Result<()> {
        // Windows SendInput (VK_CONTROL + VK_V)
        use std::process::Command;
        let _ = Command::new("powershell")
            .args(["-Command", "[System.Windows.Forms.SendKeys]::SendWait('^v')"])
            .output();
        Ok(())
    }

    #[cfg(target_os = "linux")]
    fn simulate_paste() -> Result<()> {
        use std::process::Command;
        let is_wayland = std::env::var("XDG_SESSION_TYPE")
            .map(|s| s.to_lowercase() == "wayland")
            .unwrap_or(false);

        if is_wayland {
            let _ = Command::new("wtype")
                .args(["-M", "ctrl", "-k", "v", "-m", "ctrl"])
                .output();
        } else {
            let _ = Command::new("xdotool")
                .args(["key", "--clearmodifiers", "ctrl+v"])
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

#[cfg(target_os = "macos")]
#[link(name = "AppKit", kind = "framework")]
#[link(name = "Foundation", kind = "framework")]
extern "C" {}

#[cfg(target_os = "macos")]
pub fn frontmost_pid() -> Option<i32> {
    use objc::runtime::Object;
    use objc::{class, msg_send, sel, sel_impl};
    unsafe {
        let ws: *mut Object = msg_send![class!(NSWorkspace), sharedWorkspace];
        if ws.is_null() {
            return None;
        }
        let app: *mut Object = msg_send![ws, frontmostApplication];
        if app.is_null() {
            return None;
        }
        let pid: i32 = msg_send![app, processIdentifier];
        if pid > 0 {
            Some(pid)
        } else {
            None
        }
    }
}

#[cfg(not(target_os = "macos"))]
pub fn frontmost_pid() -> Option<i32> {
    None
}

#[cfg(target_os = "macos")]
fn activate_pid(pid: i32) {
    use objc::runtime::Object;
    use objc::{class, msg_send, sel, sel_impl};
    unsafe {
        let app: *mut Object = msg_send![
            class!(NSRunningApplication),
            runningApplicationWithProcessIdentifier: pid
        ];
        if !app.is_null() {
            // NSApplicationActivateIgnoringOtherApps = 1 << 1
            let _: bool = msg_send![app, activateWithOptions: 2u64];
        }
    }
}

#[cfg(target_os = "macos")]
fn accessibility_trusted() -> bool {
    #[link(name = "ApplicationServices", kind = "framework")]
    extern "C" {
        fn AXIsProcessTrusted() -> u8;
    }
    unsafe { AXIsProcessTrusted() != 0 }
}

#[cfg(target_os = "macos")]
fn write_transient_text(text: &str) -> Result<()> {
    use objc::runtime::Object;
    use objc::{class, msg_send, sel, sel_impl};

    fn ns_string(text: &str) -> Result<*mut Object> {
        let c = std::ffi::CString::new(text).context("Clipboard text contains a null byte")?;
        unsafe {
            let raw: *mut Object = msg_send![class!(NSString), alloc];
            let obj: *mut Object = msg_send![raw, initWithUTF8String: c.as_ptr()];
            if obj.is_null() {
                anyhow::bail!("Failed to allocate pasteboard string");
            }
            Ok(obj)
        }
    }

    unsafe {
        let pool: *mut Object = msg_send![class!(NSAutoreleasePool), new];
        let result = (|| -> Result<()> {
            let item: *mut Object = msg_send![class!(NSPasteboardItem), alloc];
            let item: *mut Object = msg_send![item, init];
            if item.is_null() {
                anyhow::bail!("Failed to allocate pasteboard item");
            }
            let body = ns_string(text)?;
            let plain = ns_string("public.utf8-plain-text")?;
            let wrote: bool = msg_send![item, setString: body forType: plain];
            if !wrote {
                anyhow::bail!("Pasteboard rejected the transcript");
            }
            for marker in [
                "org.nspasteboard.TransientType",
                "org.nspasteboard.ConcealedType",
                "org.nspasteboard.AutoGeneratedType",
            ] {
                let empty = ns_string("")?;
                let kind = ns_string(marker)?;
                let _: bool = msg_send![item, setString: empty forType: kind];
            }
            let array: *mut Object = msg_send![class!(NSArray), arrayWithObject: item];
            let board: *mut Object = msg_send![class!(NSPasteboard), generalPasteboard];
            let _: isize = msg_send![board, clearContents];
            let ok: bool = msg_send![board, writeObjects: array];
            if !ok {
                anyhow::bail!("Pasteboard writeObjects failed");
            }
            Ok(())
        })();
        let _: () = msg_send![pool, drain];
        result
    }
}
