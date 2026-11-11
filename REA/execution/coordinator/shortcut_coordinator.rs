//! Global Shortcut Coordinator State Machine
//! Accurately maps low-level KeyDown and KeyUp events into high-level dictation actions:
//! - Hold-to-Talk (Push-to-Talk)
//! - Double-Tap for Hands-Free mode
//! - Escape / Cancellation

use std::time::{Duration, Instant};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KeyEdge {
    Down,
    Up,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DictationAction {
    /// Start push-to-talk capture immediately.
    StartPushToTalk,
    /// Upgrade open recording session to persistent hands-free mode.
    LockHandsFree,
    /// Finish speech recording and initiate transcription & injection.
    CommitAndTranscribe,
    /// Drop audio buffers and cancel the take completely.
    CancelTake,
    /// No action required.
    None,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Phase {
    Idle,
    Holding { down_at: Instant },
    PendingDoubleTap { down_at: Instant },
    HandsFree,
    BusyProcessing,
}

pub struct ShortcutCoordinator {
    phase: Phase,
    double_tap_enabled: bool,
    hold_threshold: Duration,
    double_tap_window: Duration,
}

impl ShortcutCoordinator {
    pub fn new() -> Self {
        Self {
            phase: Phase::Idle,
            double_tap_enabled: true,
            hold_threshold: Duration::from_millis(300),
            double_tap_window: Duration::from_millis(350),
        }
    }

    /// Process a key edge (Down or Up) for the configured hotkey.
    pub fn on_hotkey_edge(&mut self, edge: KeyEdge, now: Instant) -> DictationAction {
        match (self.phase, edge) {
            // In Hands-Free mode, pressing the hotkey commits the session
            (Phase::HandsFree, KeyEdge::Down) => {
                self.phase = Phase::BusyProcessing;
                DictationAction::CommitAndTranscribe
            }

            // In Busy mode, pressing the hotkey acts as an emergency cancel
            (Phase::BusyProcessing, KeyEdge::Down) => {
                self.phase = Phase::Idle;
                DictationAction::CancelTake
            }

            // Second tap arrived within double_tap_window -> Lock Hands-Free
            (Phase::PendingDoubleTap { down_at }, KeyEdge::Down)
                if self.double_tap_enabled && now.duration_since(down_at) <= self.double_tap_window =>
            {
                self.phase = Phase::HandsFree;
                DictationAction::LockHandsFree
            }

            // Fresh press from Idle or after window timeout -> Start Push-to-Talk
            (Phase::Idle, KeyEdge::Down) | (Phase::PendingDoubleTap { .. }, KeyEdge::Down) => {
                self.phase = Phase::Holding { down_at: now };
                DictationAction::StartPushToTalk
            }

            // Key released after hold
            (Phase::Holding { down_at }, KeyEdge::Up) => {
                let duration = now.saturating_duration_since(down_at);
                if duration >= self.hold_threshold || !self.double_tap_enabled {
                    // Held long enough: transcribe what was spoken
                    self.phase = Phase::BusyProcessing;
                    DictationAction::CommitAndTranscribe
                } else {
                    // Short tap: wait to see if a second tap follows
                    self.phase = Phase::PendingDoubleTap { down_at };
                    DictationAction::None
                }
            }

            _ => DictationAction::None,
        }
    }

    /// Explicit cancellation trigger (e.g. Escape key pressed).
    pub fn on_cancel(&mut self) -> DictationAction {
        if self.phase != Phase::Idle {
            self.phase = Phase::Idle;
            DictationAction::CancelTake
        } else {
            DictationAction::None
        }
    }

    /// Periodic tick timer to evaluate timeouts for pending double-taps.
    pub fn on_tick(&mut self, now: Instant) -> DictationAction {
        if let Phase::PendingDoubleTap { down_at } = self.phase {
            if now.saturating_duration_since(down_at) >= self.double_tap_window {
                // User tapped once and did not follow up; discard the short blip
                self.phase = Phase::Idle;
                return DictationAction::CancelTake;
            }
        }
        DictationAction::None
    }

    /// Reset coordinator state back to Idle when processing completes.
    pub fn on_processing_complete(&mut self) {
        if self.phase == Phase::BusyProcessing {
            self.phase = Phase::Idle;
        }
    }
}
