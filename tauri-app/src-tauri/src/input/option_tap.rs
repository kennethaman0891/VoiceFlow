use std::time::{Duration, Instant};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OptionGesture {
    None,
    DoubleTap,
}

/// Two quick presses of either Option key, with no other key in between.
///
/// Option+Space still belongs to push-to-talk. A press that includes Space,
/// Command, or any other key is not a tap, so the two gestures do not collide.
pub struct OptionTapMachine {
    held: [bool; 2],
    active: Option<usize>,
    down_at: Option<Instant>,
    dirty: bool,
    last_clean_up: Option<Instant>,
    tap_max: Duration,
    double_window: Duration,
}

impl OptionTapMachine {
    pub const fn new() -> Self {
        Self {
            held: [false, false],
            active: None,
            down_at: None,
            dirty: false,
            last_clean_up: None,
            tap_max: Duration::from_millis(280),
            double_window: Duration::from_millis(450),
        }
    }

    /// `index` 0 is Left Option, 1 is Right Option.
    pub fn on_option_key(&mut self, index: usize, is_down: bool, now: Instant) -> OptionGesture {
        if index > 1 || self.held[index] == is_down {
            return OptionGesture::None;
        }
        self.held[index] = is_down;
        let other = self.held[1 - index];
        if is_down {
            if other || self.active.is_some() {
                self.dirty = true;
                return OptionGesture::None;
            }
            self.active = Some(index);
            self.down_at = Some(now);
            self.dirty = false;
            return OptionGesture::None;
        }
        if self.active != Some(index) {
            self.dirty = true;
            self.active = None;
            self.down_at = None;
            self.last_clean_up = None;
            return OptionGesture::None;
        }
        self.active = None;
        let started = self.down_at.take();
        let dirty = self.dirty || other;
        self.dirty = false;
        let Some(started) = started else {
            return OptionGesture::None;
        };
        if dirty || now.saturating_duration_since(started) > self.tap_max {
            self.last_clean_up = None;
            return OptionGesture::None;
        }
        if let Some(previous) = self.last_clean_up {
            if now.saturating_duration_since(previous) <= self.double_window {
                self.last_clean_up = None;
                return OptionGesture::DoubleTap;
            }
        }
        self.last_clean_up = Some(now);
        OptionGesture::None
    }

    /// A non-Option key, or another modifier, breaks the tap sequence.
    pub fn on_other_key(&mut self) {
        if self.active.is_some() {
            self.dirty = true;
        }
        self.last_clean_up = None;
    }

    pub fn on_system_event(
        &mut self,
        event_type: u32,
        keycode: u16,
        flags: u64,
        now: Instant,
    ) -> OptionGesture {
        const KEY_DOWN: u32 = 10;
        const FLAGS_CHANGED: u32 = 12;
        const ALT: u64 = 0x0008_0000;
        if event_type == FLAGS_CHANGED {
            let index = match keycode {
                58 => 0,
                61 => 1,
                _ => {
                    self.on_other_key();
                    return OptionGesture::None;
                }
            };
            let bit = if index == 0 { 0x20 } else { 0x40 };
            let is_down = if flags & bit != 0 {
                true
            } else if flags & ALT == 0 {
                false
            } else {
                // This key changed and Option is still down, but the per-key
                // bit is missing. The key moved to the other state.
                !self.held[index]
            };
            return self.on_option_key(index, is_down, now);
        }
        if event_type == KEY_DOWN {
            self.on_other_key();
        }
        OptionGesture::None
    }
}

impl Default for OptionTapMachine {
    fn default() -> Self {
        Self::new()
    }
}

/// Starts the macOS listener. Each item on the receiver is one double-tap.
/// Other platforms return `None`.
pub fn start() -> Option<crossbeam_channel::Receiver<()>> {
    #[cfg(target_os = "macos")]
    {
        macos::start()
    }
    #[cfg(not(target_os = "macos"))]
    {
        None
    }
}

#[cfg(target_os = "macos")]
mod macos {
    use super::{OptionGesture, OptionTapMachine};
    use std::ffi::c_void;
    use std::sync::atomic::{AtomicBool, AtomicPtr, Ordering};
    use std::sync::{Mutex, OnceLock};
    use std::time::{Duration, Instant};

    static STARTED: AtomicBool = AtomicBool::new(false);
    static TAP_TX: OnceLock<crossbeam_channel::Sender<()>> = OnceLock::new();
    static TAP_PORT: AtomicPtr<c_void> = AtomicPtr::new(std::ptr::null_mut());
    static MACHINE: Mutex<OptionTapMachine> = Mutex::new(OptionTapMachine::new());

    pub fn start() -> Option<crossbeam_channel::Receiver<()>> {
        if STARTED.swap(true, Ordering::SeqCst) {
            return None;
        }
        let (tx, rx) = crossbeam_channel::bounded(8);
        if TAP_TX.set(tx).is_err() {
            return None;
        }
        std::thread::Builder::new()
            .name("voiceflow-option-tap".into())
            .spawn(run_loop)
            .ok()?;
        Some(rx)
    }

    fn run_loop() {
        let mut announced = false;
        loop {
            let tap = unsafe { create_tap() };
            if tap.is_null() {
                if !announced {
                    log::warn!(
                        "Double-tap Option needs Accessibility permission for VoiceFlow. Retrying."
                    );
                    announced = true;
                }
                std::thread::sleep(Duration::from_secs(3));
                continue;
            }
            TAP_PORT.store(tap, Ordering::SeqCst);
            log::info!("Option double-tap listener is running");
            unsafe {
                let source = CFMachPortCreateRunLoopSource(std::ptr::null(), tap, 0);
                if !source.is_null() {
                    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, kCFRunLoopCommonModes);
                }
                CGEventTapEnable(tap, true);
                CFRunLoopRun();
            }
            TAP_PORT.store(std::ptr::null_mut(), Ordering::SeqCst);
            std::thread::sleep(Duration::from_secs(1));
        }
    }

    unsafe fn create_tap() -> *mut c_void {
        const SESSION: u32 = 1;
        const TAIL: u32 = 1;
        const LISTEN_ONLY: u32 = 1;
        const KEY_DOWN: u64 = 1 << 10;
        const KEY_UP: u64 = 1 << 11;
        const FLAGS: u64 = 1 << 12;
        CGEventTapCreate(
            SESSION,
            TAIL,
            LISTEN_ONLY,
            KEY_DOWN | KEY_UP | FLAGS,
            tap_callback,
            std::ptr::null_mut(),
        )
    }

    extern "C" fn tap_callback(
        _proxy: *mut c_void,
        event_type: u32,
        event: *mut c_void,
        _user: *mut c_void,
    ) -> *mut c_void {
        const DISABLED_TIMEOUT: u32 = 0xFFFF_FFFE;
        const DISABLED_USER: u32 = 0xFFFF_FFFF;
        if event_type == DISABLED_TIMEOUT || event_type == DISABLED_USER {
            let port = TAP_PORT.load(Ordering::SeqCst);
            if !port.is_null() {
                unsafe { CGEventTapEnable(port, true) };
            }
            return event;
        }
        if event.is_null() {
            return event;
        }
        let keycode = unsafe { CGEventGetIntegerValueField(event, 9) } as u16;
        let flags = unsafe { CGEventGetFlags(event) };
        let gesture = MACHINE.lock().map(|mut machine| {
            machine.on_system_event(event_type, keycode, flags, Instant::now())
        });
        if matches!(gesture, Ok(OptionGesture::DoubleTap)) {
            if let Some(tx) = TAP_TX.get() {
                let _ = tx.try_send(());
            }
        }
        event
    }

    #[link(name = "CoreGraphics", kind = "framework")]
    #[link(name = "CoreFoundation", kind = "framework")]
    extern "C" {
        static kCFRunLoopCommonModes: *const c_void;

        fn CGEventTapCreate(
            tap: u32,
            place: u32,
            options: u32,
            events: u64,
            callback: extern "C" fn(*mut c_void, u32, *mut c_void, *mut c_void) -> *mut c_void,
            user_info: *mut c_void,
        ) -> *mut c_void;

        fn CGEventTapEnable(tap: *mut c_void, enable: bool);
        fn CGEventGetIntegerValueField(event: *mut c_void, field: u32) -> i64;
        fn CGEventGetFlags(event: *mut c_void) -> u64;
        fn CFMachPortCreateRunLoopSource(
            allocator: *const c_void,
            port: *mut c_void,
            order: isize,
        ) -> *mut c_void;
        fn CFRunLoopGetCurrent() -> *mut c_void;
        fn CFRunLoopAddSource(rl: *mut c_void, source: *mut c_void, mode: *const c_void);
        fn CFRunLoopRun();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn t0() -> Instant {
        Instant::now()
    }

    fn tap(machine: &mut OptionTapMachine, start: Instant, at_ms: u64) {
        let down = start + Duration::from_millis(at_ms);
        let up = down + Duration::from_millis(60);
        assert_eq!(
            machine.on_option_key(0, true, down),
            OptionGesture::None
        );
        let _ = machine.on_option_key(0, false, up);
    }

    #[test]
    fn two_quick_option_presses_are_a_double_tap() {
        let mut machine = OptionTapMachine::new();
        let start = t0();
        assert_eq!(
            machine.on_option_key(0, true, start),
            OptionGesture::None
        );
        assert_eq!(
            machine.on_option_key(0, false, start + Duration::from_millis(70)),
            OptionGesture::None
        );
        assert_eq!(
            machine.on_option_key(0, true, start + Duration::from_millis(180)),
            OptionGesture::None
        );
        assert_eq!(
            machine.on_option_key(0, false, start + Duration::from_millis(240)),
            OptionGesture::DoubleTap
        );
    }

    #[test]
    fn a_single_tap_does_nothing() {
        let mut machine = OptionTapMachine::new();
        let start = t0();
        machine.on_option_key(0, true, start);
        assert_eq!(
            machine.on_option_key(0, false, start + Duration::from_millis(80)),
            OptionGesture::None
        );
    }

    #[test]
    fn option_plus_space_is_not_a_tap() {
        let mut machine = OptionTapMachine::new();
        let start = t0();
        machine.on_option_key(0, true, start);
        machine.on_other_key();
        assert_eq!(
            machine.on_option_key(0, false, start + Duration::from_millis(40)),
            OptionGesture::None
        );
        machine.on_option_key(0, true, start + Duration::from_millis(120));
        assert_eq!(
            machine.on_option_key(0, false, start + Duration::from_millis(180)),
            OptionGesture::None
        );
    }

    #[test]
    fn a_held_option_key_is_not_a_tap() {
        let mut machine = OptionTapMachine::new();
        let start = t0();
        machine.on_option_key(0, true, start);
        assert_eq!(
            machine.on_option_key(0, false, start + Duration::from_millis(400)),
            OptionGesture::None
        );
    }

    #[test]
    fn left_then_right_option_counts() {
        let mut machine = OptionTapMachine::new();
        let start = t0();
        machine.on_option_key(0, true, start);
        machine.on_option_key(0, false, start + Duration::from_millis(50));
        machine.on_option_key(1, true, start + Duration::from_millis(160));
        assert_eq!(
            machine.on_option_key(1, false, start + Duration::from_millis(210)),
            OptionGesture::DoubleTap
        );
    }

    #[test]
    fn holding_both_option_keys_is_not_a_tap() {
        let mut machine = OptionTapMachine::new();
        let start = t0();
        machine.on_option_key(0, true, start);
        machine.on_option_key(1, true, start + Duration::from_millis(30));
        assert_eq!(
            machine.on_option_key(0, false, start + Duration::from_millis(80)),
            OptionGesture::None
        );
        assert_eq!(
            machine.on_option_key(1, false, start + Duration::from_millis(100)),
            OptionGesture::None
        );
    }

    #[test]
    fn a_slow_second_press_starts_a_new_sequence() {
        let mut machine = OptionTapMachine::new();
        let start = t0();
        tap(&mut machine, start, 0);
        machine.on_option_key(0, true, start + Duration::from_millis(800));
        assert_eq!(
            machine.on_option_key(0, false, start + Duration::from_millis(860)),
            OptionGesture::None
        );
    }

    #[test]
    fn system_event_uses_the_option_keycode_and_ignores_space() {
        let mut machine = OptionTapMachine::new();
        let start = t0();
        const FLAGS: u32 = 12;
        const KEY_DOWN: u32 = 10;
        const LEFT_DOWN: u64 = 0x20 | 0x0008_0000;
        assert_eq!(
            machine.on_system_event(FLAGS, 58, LEFT_DOWN, start),
            OptionGesture::None
        );
        assert_eq!(
            machine.on_system_event(KEY_DOWN, 49, LEFT_DOWN, start + Duration::from_millis(20)),
            OptionGesture::None
        );
        assert_eq!(
            machine.on_system_event(FLAGS, 58, 0, start + Duration::from_millis(40)),
            OptionGesture::None
        );
    }
}
