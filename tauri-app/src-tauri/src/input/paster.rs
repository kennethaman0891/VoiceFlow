use anyhow::{Context, Result};
use arboard::Clipboard;
use std::ffi::c_void;
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
        #[cfg(target_os = "macos")]
        {
            let _clipboard = &self.cb;
            return deliver_transcript(text, reactivate_pid);
        }
        #[cfg(not(target_os = "macos"))]
        {
            let cb = self.cb.as_mut().context("Clipboard not available")?;
            let previous_text = cb.get_text().ok();
            let _ = reactivate_pid;
            cb.set_text(text.to_string())
                .context("Failed to set clipboard text")?;
            sleep(Duration::from_millis(35));
            Self::simulate_paste()?;
            sleep(Duration::from_millis(220));
            if let Some(prev) = previous_text {
                let _ = cb.set_text(prev);
            }
            Ok(())
        }
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
        if app.is_null() {
            return;
        }
        let nsapp: *mut Object = msg_send![class!(NSApplication), sharedApplication];
        let yield_sel = sel!(yieldActivationToApplication:);
        let can_yield: bool = msg_send![nsapp, respondsToSelector: yield_sel];
        if can_yield {
            let _: bool = msg_send![nsapp, yieldActivationToApplication: app];
        } else {
            // NSApplicationActivateIgnoringOtherApps = 1 << 1
            let _: bool = msg_send![app, activateWithOptions: 2u64];
        }
    }
}

/// Keep the real target app. A later sample that is VoiceFlow itself must not
/// replace Notes, Chrome, or whichever field the user was typing in.
pub fn next_target(previous: Option<i32>, seen: Option<i32>, our_pid: i32) -> Option<i32> {
    match seen {
        Some(pid) if pid > 0 && pid != our_pid => Some(pid),
        _ => previous.filter(|pid| *pid > 0 && *pid != our_pid),
    }
}

/// Activate `saved` only when the focused app is not already that target.
pub fn activation_target(
    our_pid: i32,
    focused_pid: Option<i32>,
    saved_pid: Option<i32>,
) -> Option<i32> {
    let saved = match saved_pid {
        Some(pid) if pid > 0 && pid != our_pid => pid,
        _ => return None,
    };
    match focused_pid {
        Some(pid) if pid == saved => None,
        _ => Some(saved),
    }
}

#[cfg(target_os = "macos")]
fn accessibility_trusted() -> bool {
    ax_is_trusted() != 0
}

#[cfg(target_os = "macos")]
fn ax_is_trusted() -> u8 {
    #[link(name = "ApplicationServices", kind = "framework")]
    extern "C" {
        fn AXIsProcessTrusted() -> u8;
    }
    unsafe { AXIsProcessTrusted() }
}

/// Ask macOS once, at launch, if VoiceFlow cannot yet insert text.
pub fn prompt_accessibility_if_needed() {
    #[cfg(target_os = "macos")]
    {
        if accessibility_trusted() {
            return;
        }
        unsafe {
            prompt_accessibility_dialog();
        }
    }
}

#[cfg(target_os = "macos")]
unsafe fn prompt_accessibility_dialog() {
    use objc::runtime::Object;
    use objc::{class, msg_send, sel, sel_impl};

    #[link(name = "ApplicationServices", kind = "framework")]
    extern "C" {
        fn AXIsProcessTrustedWithOptions(options: *mut c_void) -> u8;
    }
    let pool: *mut Object = msg_send![class!(NSAutoreleasePool), new];
    let key = ns_string("AXTrustedCheckOptionPrompt");
    if let Ok(key) = key {
        let yes: *mut Object = msg_send![class!(NSNumber), numberWithBool: true];
        let opts: *mut Object =
            msg_send![class!(NSDictionary), dictionaryWithObject: yes forKey: key];
        let _trusted = AXIsProcessTrustedWithOptions(opts as *mut c_void);
        release(key);
    }
    let _: () = msg_send![pool, drain];
}

#[cfg(target_os = "macos")]
fn deliver_transcript(text: &str, saved_pid: Option<i32>) -> Result<()> {
    let text = text.replace('\0', "");
    if text.trim().is_empty() {
        return Ok(());
    }
    if !accessibility_trusted() {
        let _ = write_clipboard(&text);
        anyhow::bail!(
            "Copied. Grant Accessibility to VoiceFlow in System Settings to paste automatically."
        );
    }
    let saved_pid = saved_pid.filter(|pid| *pid > 0);
    crate::platform::on_main_sync(move || insert_on_main(&text, saved_pid))
        .map_err(anyhow::Error::msg)?
}

#[cfg(target_os = "macos")]
fn insert_on_main(text: &str, saved_pid: Option<i32>) -> Result<()> {
    resign_our_key_window();
    sleep(Duration::from_millis(30));
    let ours = std::process::id() as i32;
    if let Some(pid) = activation_target(ours, focused_pid(), saved_pid) {
        activate_pid(pid);
        sleep(Duration::from_millis(70));
    }
    if insert_selected_text(text) {
        return Ok(());
    }
    let previous = read_clipboard();
    write_clipboard(text)?;
    let written = pasteboard_change_count();
    if let Some(pid) = activation_target(ours, focused_pid(), saved_pid) {
        activate_pid(pid);
        sleep(Duration::from_millis(50));
    }
    let pasted = Paster::simulate_paste();
    // Wait until the target has read the pasteboard. Restoring sooner puts
    // the previous clipboard contents into the field instead of the transcript.
    // If the count moved, the user copied something else and we leave it.
    sleep(Duration::from_millis(420));
    if pasteboard_change_count() == written {
        restore_clipboard(previous);
    }
    pasted
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
            // Transient keeps the transcript out of clipboard history.
            // Concealed and auto-generated markers make some apps drop the paste.
            for marker in ["org.nspasteboard.TransientType"] {
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

#[cfg(target_os = "macos")]
fn write_clipboard(text: &str) -> Result<()> {
    write_transient_text(text)
}

#[cfg(target_os = "macos")]
fn pasteboard_change_count() -> isize {
    use objc::runtime::Object;
    use objc::{class, msg_send, sel, sel_impl};
    unsafe {
        let board: *mut Object = msg_send![class!(NSPasteboard), generalPasteboard];
        msg_send![board, changeCount]
    }
}

#[cfg(target_os = "macos")]
fn read_clipboard() -> Option<String> {
    use objc::runtime::Object;
    use objc::{class, msg_send, sel, sel_impl};
    unsafe {
        let pool: *mut Object = msg_send![class!(NSAutoreleasePool), new];
        let text = (|| {
            let board: *mut Object = msg_send![class!(NSPasteboard), generalPasteboard];
            let kind = ns_string("public.utf8-plain-text").ok()?;
            let value: *mut Object = msg_send![board, stringForType: kind];
            release(kind);
            if value.is_null() {
                return None;
            }
            let bytes: *const i8 = msg_send![value, UTF8String];
            if bytes.is_null() {
                return None;
            }
            Some(std::ffi::CStr::from_ptr(bytes).to_string_lossy().into_owned())
        })();
        let _: () = msg_send![pool, drain];
        text
    }
}

#[cfg(target_os = "macos")]
fn restore_clipboard(previous: Option<String>) {
    use objc::runtime::Object;
    use objc::{class, msg_send, sel, sel_impl};
    unsafe {
        let pool: *mut Object = msg_send![class!(NSAutoreleasePool), new];
        let board: *mut Object = msg_send![class!(NSPasteboard), generalPasteboard];
        let _: isize = msg_send![board, clearContents];
        if let Some(previous) = previous {
            if let Ok(value) = ns_string(&previous) {
                let kind = ns_string("public.utf8-plain-text");
                if let Ok(kind) = kind {
                    let _: bool = msg_send![board, setString: value forType: kind];
                    release(kind);
                }
                release(value);
            }
        }
        let _: () = msg_send![pool, drain];
    }
}

#[cfg(target_os = "macos")]
fn resign_our_key_window() {
    use objc::runtime::Object;
    use objc::{class, msg_send, sel, sel_impl};
    unsafe {
        let app: *mut Object = msg_send![class!(NSApplication), sharedApplication];
        if app.is_null() {
            return;
        }
        let windows: *mut Object = msg_send![app, windows];
        if windows.is_null() {
            return;
        }
        let count: usize = msg_send![windows, count];
        for index in 0..count {
            let window: *mut Object = msg_send![windows, objectAtIndex: index];
            if window.is_null() {
                continue;
            }
            let is_key: bool = msg_send![window, isKeyWindow];
            if is_key {
                let _: () = msg_send![window, resignKeyWindow];
            }
        }
    }
}

#[cfg(target_os = "macos")]
fn focused_pid() -> Option<i32> {
    unsafe { ax_focused_pid() }
}

#[cfg(target_os = "macos")]
unsafe fn ax_focused_pid() -> Option<i32> {
    #[link(name = "ApplicationServices", kind = "framework")]
    extern "C" {
        fn AXUIElementCreateSystemWide() -> *mut c_void;
        fn AXUIElementCopyAttributeValue(
            element: *mut c_void,
            attribute: *mut c_void,
            value: *mut *mut c_void,
        ) -> i32;
        fn AXUIElementGetPid(element: *mut c_void, pid: *mut i32) -> i32;
        fn CFRelease(cf: *const c_void);
    }
    let system = AXUIElementCreateSystemWide();
    if system.is_null() {
        return None;
    }
    let Ok(attr) = ns_string("AXFocusedUIElement") else {
        CFRelease(system);
        return None;
    };
    let mut element: *mut c_void = std::ptr::null_mut();
    let err = AXUIElementCopyAttributeValue(system, attr as *mut c_void, &mut element);
    CFRelease(system);
    release(attr);
    if err != 0 || element.is_null() {
        return None;
    }
    let mut pid = 0i32;
    let pid_err = AXUIElementGetPid(element, &mut pid);
    CFRelease(element);
    if pid_err == 0 && pid > 0 {
        Some(pid)
    } else {
        None
    }
}

/// Insert at the caret by replacing the selection. An empty selection inserts.
#[cfg(target_os = "macos")]
fn insert_selected_text(text: &str) -> bool {
    unsafe { ax_insert_selected_text(text) }
}

#[cfg(target_os = "macos")]
unsafe fn ax_insert_selected_text(text: &str) -> bool {
    use objc::runtime::Object;
    use objc::{class, msg_send, sel, sel_impl};
    #[link(name = "ApplicationServices", kind = "framework")]
    extern "C" {
        fn AXUIElementCreateSystemWide() -> *mut c_void;
        fn AXUIElementCopyAttributeValue(
            element: *mut c_void,
            attribute: *mut c_void,
            value: *mut *mut c_void,
        ) -> i32;
        fn AXUIElementIsAttributeSettable(
            element: *mut c_void,
            attribute: *mut c_void,
            settable: *mut u8,
        ) -> i32;
        fn AXUIElementSetAttributeValue(
            element: *mut c_void,
            attribute: *mut c_void,
            value: *mut c_void,
        ) -> i32;
        fn CFRelease(cf: *const c_void);
    }

    let pool: *mut Object = msg_send![class!(NSAutoreleasePool), new];
    let inserted = (|| {
        let system = AXUIElementCreateSystemWide();
        if system.is_null() {
            return false;
        }
        let Ok(focused_attr) = ns_string("AXFocusedUIElement") else {
            CFRelease(system);
            return false;
        };
        let mut element: *mut c_void = std::ptr::null_mut();
        let err = AXUIElementCopyAttributeValue(system, focused_attr as *mut c_void, &mut element);
        CFRelease(system);
        release(focused_attr);
        if err != 0 || element.is_null() {
            return false;
        }
        let Ok(selected_attr) = ns_string("AXSelectedText") else {
            CFRelease(element);
            return false;
        };
        let mut settable: u8 = 0;
        let set_err =
            AXUIElementIsAttributeSettable(element, selected_attr as *mut c_void, &mut settable);
        if set_err != 0 || settable == 0 {
            release(selected_attr);
            CFRelease(element);
            return false;
        }
        let Ok(value) = ns_string(text) else {
            release(selected_attr);
            CFRelease(element);
            return false;
        };
        let write_err =
            AXUIElementSetAttributeValue(element, selected_attr as *mut c_void, value as *mut c_void);
        release(value);
        release(selected_attr);
        CFRelease(element);
        write_err == 0
    })();
    let _: () = msg_send![pool, drain];
    inserted
}

#[cfg(target_os = "macos")]
fn ns_string(text: &str) -> Result<*mut objc::runtime::Object> {
    use objc::runtime::Object;
    use objc::{class, msg_send, sel, sel_impl};
    let c = std::ffi::CString::new(text).context("Text contains a null byte")?;
    unsafe {
        let raw: *mut Object = msg_send![class!(NSString), alloc];
        let obj: *mut Object = msg_send![raw, initWithUTF8String: c.as_ptr()];
        if obj.is_null() {
            anyhow::bail!("Failed to allocate string");
        }
        Ok(obj)
    }
}

#[cfg(target_os = "macos")]
fn release(obj: *mut objc::runtime::Object) {
    use objc::{msg_send, sel, sel_impl};
    if !obj.is_null() {
        unsafe {
            let _: () = msg_send![obj, release];
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{activation_target, next_target};

    #[test]
    fn target_ignores_our_own_pid_and_keeps_the_previous_app() {
        assert_eq!(next_target(Some(40), Some(7), 7), Some(40));
        assert_eq!(next_target(Some(40), Some(55), 7), Some(55));
        assert_eq!(next_target(None, Some(7), 7), None);
        assert_eq!(next_target(Some(7), None, 7), None);
    }

    #[test]
    fn activation_skips_when_the_target_is_already_focused() {
        assert_eq!(activation_target(7, Some(40), Some(40)), None);
        assert_eq!(activation_target(7, Some(7), Some(40)), Some(40));
        assert_eq!(activation_target(7, None, Some(40)), Some(40));
        assert_eq!(activation_target(7, Some(40), Some(7)), None);
    }
}
