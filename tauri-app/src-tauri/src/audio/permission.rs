//! Microphone permission, checked before a capture pretends to be listening.

#[cfg(target_os = "macos")]
#[link(name = "AVFoundation", kind = "framework")]
extern "C" {}

/// `Some` when VoiceFlow is not allowed to hear the microphone.
/// Not-determined is `None` so the first capture can raise the system prompt.
pub fn denial_message() -> Option<String> {
    #[cfg(target_os = "macos")]
    {
        unsafe { macos_denial() }
    }
    #[cfg(not(target_os = "macos"))]
    {
        None
    }
}

#[cfg(target_os = "macos")]
unsafe fn macos_denial() -> Option<String> {
    use objc::runtime::Class;
    use objc::{class, msg_send, sel, sel_impl};
    use std::ffi::CString;

    let cls = Class::get("AVCaptureDevice")?;
    let c_name = CString::new("soun").ok()?;
    let raw: *mut objc::runtime::Object = msg_send![class!(NSString), alloc];
    let media: *mut objc::runtime::Object = msg_send![raw, initWithUTF8String: c_name.as_ptr()];
    if media.is_null() {
        return None;
    }
    // AVAuthorizationStatus: 1 restricted, 2 denied, 3 authorized.
    let status: isize = msg_send![cls, authorizationStatusForMediaType: media];
    let _: () = msg_send![media, release];
    match status {
        1 => Some(
            "Microphone access is restricted. VoiceFlow cannot hear you.".to_string(),
        ),
        2 => Some(
            "Microphone access is off. Turn it on for VoiceFlow in System Settings, Privacy & Security, Microphone."
                .to_string(),
        ),
        _ => None,
    }
}
