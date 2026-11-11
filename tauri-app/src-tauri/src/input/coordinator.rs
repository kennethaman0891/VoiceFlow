use std::time::{Duration, Instant};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KeyEdge {
    Down,
    Up,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HotkeyAction {
    /// Begin a push-to-talk capture.
    StartPushToTalk,
    /// Upgrade the open capture to hands-free. Do not transcribe the tap.
    StartHandsFree,
    /// Stop and transcribe what was captured.
    StopAndTranscribe,
    /// Drop the audio. Do not paste.
    Cancel,
    None,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Phase {
    Idle,
    Holding { down_at: Instant },
    Pending { down_at: Instant },
    HandsFree,
    Busy,
}

/// Hold-to-talk, double-tap hands-free, and cancel.
///
/// A hold of at least 300ms transcribes on release. A shorter tap waits until
/// 350ms after the press: a second press enters hands-free, otherwise the blip
/// is discarded. Escape and a press during transcription cancel.
pub struct ShortcutCoordinator {
    phase: Phase,
    double_tap_enabled: bool,
    hold_threshold: Duration,
    double_window: Duration,
}

impl ShortcutCoordinator {
    pub fn new() -> Self {
        Self {
            phase: Phase::Idle,
            double_tap_enabled: true,
            hold_threshold: Duration::from_millis(300),
            double_window: Duration::from_millis(350),
        }
    }

    pub fn set_double_tap_enabled(&mut self, enabled: bool) {
        self.double_tap_enabled = enabled;
    }

    pub fn on_edge(&mut self, edge: KeyEdge, now: Instant) -> HotkeyAction {
        match (self.phase, edge) {
            (Phase::HandsFree, KeyEdge::Down) => {
                self.phase = Phase::Busy;
                HotkeyAction::StopAndTranscribe
            }
            (Phase::Busy, KeyEdge::Down) => {
                self.phase = Phase::Idle;
                HotkeyAction::Cancel
            }
            (Phase::Pending { down_at }, KeyEdge::Down)
                if self.double_tap_enabled && now.duration_since(down_at) <= self.double_window =>
            {
                self.phase = Phase::HandsFree;
                HotkeyAction::StartHandsFree
            }
            (Phase::Idle, KeyEdge::Down) | (Phase::Pending { .. }, KeyEdge::Down) => {
                self.phase = Phase::Holding { down_at: now };
                HotkeyAction::StartPushToTalk
            }
            (Phase::Holding { down_at }, KeyEdge::Up) => {
                let held = now.saturating_duration_since(down_at);
                if held >= self.hold_threshold || !self.double_tap_enabled {
                    self.phase = Phase::Busy;
                    HotkeyAction::StopAndTranscribe
                } else {
                    self.phase = Phase::Pending { down_at };
                    HotkeyAction::None
                }
            }
            _ => HotkeyAction::None,
        }
    }

    /// Fires when the double-tap window closes without a second press.
    pub fn on_tick(&mut self, now: Instant) -> HotkeyAction {
        if let Phase::Pending { down_at } = self.phase {
            if now.saturating_duration_since(down_at) >= self.double_window {
                self.phase = Phase::Idle;
                return HotkeyAction::Cancel;
            }
        }
        HotkeyAction::None
    }

    pub fn on_silence_stop(&mut self) -> HotkeyAction {
        if self.phase == Phase::HandsFree {
            self.phase = Phase::Busy;
            HotkeyAction::StopAndTranscribe
        } else {
            HotkeyAction::None
        }
    }

    pub fn on_silence_cancel(&mut self) -> HotkeyAction {
        if self.phase == Phase::HandsFree {
            self.phase = Phase::Idle;
            HotkeyAction::Cancel
        } else {
            HotkeyAction::None
        }
    }

    pub fn on_escape(&mut self) -> HotkeyAction {
        if self.phase == Phase::Idle {
            HotkeyAction::None
        } else {
            self.phase = Phase::Idle;
            HotkeyAction::Cancel
        }
    }

    /// A click on the pill starts a session the shortcut machine must know about.
    /// Otherwise Escape and the close button look idle and leave the mic running.
    pub fn ensure_button_session(&mut self) {
        if self.phase == Phase::Idle {
            self.phase = Phase::HandsFree;
        }
    }

    /// Always leave the shortcut machine idle. Callers stop the recorder themselves.
    pub fn cancel_session(&mut self) -> HotkeyAction {
        self.phase = Phase::Idle;
        HotkeyAction::Cancel
    }

    pub fn mark_busy(&mut self) {
        if self.phase != Phase::Idle {
            self.phase = Phase::Busy;
        }
    }

    pub fn pending_deadline(&self) -> Option<Instant> {
        match self.phase {
            Phase::Pending { down_at } => Some(down_at + self.double_window),
            _ => None,
        }
    }

    pub fn force_idle(&mut self) {
        self.phase = Phase::Idle;
    }

    pub fn is_hands_free(&self) -> bool {
        self.phase == Phase::HandsFree
    }

    /// Double-tap of the Option key alone. Hold Option+Space is unchanged.
    /// A second double-tap commits the take. Escape still cancels.
    pub fn on_option_double_tap(&mut self) -> HotkeyAction {
        if !self.double_tap_enabled {
            return HotkeyAction::None;
        }
        match self.phase {
            Phase::Idle => {
                self.phase = Phase::HandsFree;
                HotkeyAction::StartHandsFree
            }
            Phase::HandsFree => {
                self.phase = Phase::Busy;
                HotkeyAction::StopAndTranscribe
            }
            Phase::Busy => {
                self.phase = Phase::Idle;
                HotkeyAction::Cancel
            }
            // An Option+Space hold or a pending blip owns the machine.
            Phase::Holding { .. } | Phase::Pending { .. } => HotkeyAction::None,
        }
    }
}

impl Default for ShortcutCoordinator {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn t0() -> Instant {
        Instant::now()
    }

    #[test]
    fn hold_transcribes_on_release() {
        let mut c = ShortcutCoordinator::new();
        let start = t0();
        assert_eq!(
            c.on_edge(KeyEdge::Down, start),
            HotkeyAction::StartPushToTalk
        );
        assert_eq!(
            c.on_edge(KeyEdge::Up, start + Duration::from_millis(400)),
            HotkeyAction::StopAndTranscribe
        );
    }

    #[test]
    fn double_tap_within_350ms_enters_hands_free_without_pasting_the_blip() {
        let mut c = ShortcutCoordinator::new();
        let start = t0();
        assert_eq!(
            c.on_edge(KeyEdge::Down, start),
            HotkeyAction::StartPushToTalk
        );
        assert_eq!(
            c.on_edge(KeyEdge::Up, start + Duration::from_millis(80)),
            HotkeyAction::None
        );
        assert_eq!(
            c.on_edge(KeyEdge::Down, start + Duration::from_millis(200)),
            HotkeyAction::StartHandsFree
        );
        assert!(c.is_hands_free());
    }

    #[test]
    fn single_short_tap_cancels_when_the_window_expires() {
        let mut c = ShortcutCoordinator::new();
        let start = t0();
        c.on_edge(KeyEdge::Down, start);
        c.on_edge(KeyEdge::Up, start + Duration::from_millis(100));
        assert_eq!(
            c.on_tick(start + Duration::from_millis(350)),
            HotkeyAction::Cancel
        );
    }

    #[test]
    fn escape_cancels_and_does_nothing_when_idle() {
        let mut c = ShortcutCoordinator::new();
        let start = t0();
        c.on_edge(KeyEdge::Down, start);
        assert_eq!(c.on_escape(), HotkeyAction::Cancel);
        assert_eq!(c.on_escape(), HotkeyAction::None);
    }

    #[test]
    fn pill_session_can_be_cancelled_after_the_shortcut_machine_was_idle() {
        let mut c = ShortcutCoordinator::new();
        c.ensure_button_session();
        assert!(c.is_hands_free());
        assert_eq!(c.cancel_session(), HotkeyAction::Cancel);
        assert!(!c.is_hands_free());
        assert_eq!(c.cancel_session(), HotkeyAction::Cancel);
    }

    #[test]
    fn option_double_tap_starts_hands_free_and_the_next_one_commits() {
        let mut c = ShortcutCoordinator::new();
        assert_eq!(c.on_option_double_tap(), HotkeyAction::StartHandsFree);
        assert!(c.is_hands_free());
        assert_eq!(c.on_option_double_tap(), HotkeyAction::StopAndTranscribe);
    }

    #[test]
    fn option_double_tap_respects_the_setting_and_an_open_hold() {
        let mut c = ShortcutCoordinator::new();
        c.set_double_tap_enabled(false);
        assert_eq!(c.on_option_double_tap(), HotkeyAction::None);

        let mut c = ShortcutCoordinator::new();
        let start = t0();
        c.on_edge(KeyEdge::Down, start);
        assert_eq!(c.on_option_double_tap(), HotkeyAction::None);
    }

    #[test]
    fn press_during_transcribe_cancels() {
        let mut c = ShortcutCoordinator::new();
        let start = t0();
        c.on_edge(KeyEdge::Down, start);
        c.on_edge(KeyEdge::Up, start + Duration::from_millis(400));
        assert_eq!(
            c.on_edge(KeyEdge::Down, start + Duration::from_millis(500)),
            HotkeyAction::Cancel
        );
    }
}
