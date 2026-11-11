use std::time::{Duration, Instant};

#[derive(Debug, Clone)]
pub struct VadConfig {
    pub sample_rate: u32,
    pub min_speech_duration: Duration,
    pub silence_timeout: Duration,
    pub initial_timeout: Duration,
    pub db_above_noise: f32,
}

impl Default for VadConfig {
    fn default() -> Self {
        Self {
            sample_rate: 16000,
            min_speech_duration: Duration::from_millis(300),
            silence_timeout: Duration::from_millis(2000),
            initial_timeout: Duration::from_secs(6),
            db_above_noise: 12.0,
        }
    }
}

#[derive(Debug, PartialEq, Clone)]
pub enum VadEvent {
    SpeechStarted,
    Speaking { level: f32 },
    SilenceCountdown { remaining_ms: u64, progress: f32 },
    ConfirmedSilence { trim_samples: usize },
    InitialTimeout,
}

pub struct VadDetector {
    config: VadConfig,
    noise_floor_db: f32,
    speech_start: Option<Instant>,
    quiet_start: Option<Instant>,
    silence_start: Option<Instant>,
    session_start: Instant,
    is_armed: bool,
    closed: bool,
}

impl VadDetector {
    pub fn new(config: VadConfig) -> Self {
        Self {
            config,
            noise_floor_db: -50.0,
            speech_start: None,
            quiet_start: None,
            silence_start: None,
            session_start: Instant::now(),
            is_armed: false,
            closed: false,
        }
    }

    pub fn reset(&mut self) {
        self.noise_floor_db = -50.0;
        self.speech_start = None;
        self.quiet_start = None;
        self.silence_start = None;
        self.session_start = Instant::now();
        self.is_armed = false;
        self.closed = false;
    }

    pub fn set_silence_timeout_ms(&mut self, ms: u64) {
        let ms = ms.clamp(500, 10_000);
        self.config.silence_timeout = Duration::from_millis(ms);
    }

    pub fn process_frame(&mut self, samples: &[f32]) -> Option<VadEvent> {
        if self.closed || samples.is_empty() {
            return None;
        }

        let sum_sq: f32 = samples.iter().map(|&s| s * s).sum();
        let rms = (sum_sq / samples.len() as f32).sqrt();
        let db = 20.0 * rms.max(1e-5).log10();

        let on_threshold = (self.noise_floor_db + self.config.db_above_noise).max(-42.0);
        let off_threshold = on_threshold - 6.0;
        let is_voice = if self.is_armed {
            db > off_threshold
        } else {
            db > on_threshold
        };

        let now = Instant::now();

        if is_voice {
            self.silence_start = None;
            self.quiet_start = None;

            if self.speech_start.is_none() {
                self.speech_start = Some(now);
            }

            let speech_dur = now.saturating_duration_since(self.speech_start.unwrap());
            if !self.is_armed && speech_dur >= self.config.min_speech_duration {
                self.is_armed = true;
                return Some(VadEvent::SpeechStarted);
            }

            if self.is_armed {
                return Some(VadEvent::Speaking {
                    level: (rms * 4.0).min(1.0),
                });
            }
            return None;
        }

        if !self.is_armed {
            if self.quiet_start.is_none() {
                self.quiet_start = Some(now);
            }
            if now.saturating_duration_since(self.quiet_start.unwrap()) >= Duration::from_millis(120)
            {
                self.speech_start = None;
            }
            // Drift the floor toward the room, both directions, only while idle.
            self.noise_floor_db = self.noise_floor_db * 0.98 + db * 0.02;
            self.noise_floor_db = self.noise_floor_db.clamp(-70.0, -30.0);

            if now.saturating_duration_since(self.session_start) >= self.config.initial_timeout {
                self.closed = true;
                return Some(VadEvent::InitialTimeout);
            }
            return None;
        }

        self.speech_start = None;
        if self.silence_start.is_none() {
            self.silence_start = Some(now);
        }
        let silence_dur = now.saturating_duration_since(self.silence_start.unwrap());
        if silence_dur >= self.config.silence_timeout {
            self.closed = true;
            let keep_pad = Duration::from_millis(250);
            let trim_dur = self.config.silence_timeout.saturating_sub(keep_pad);
            let trim_samples = (trim_dur.as_secs_f32() * self.config.sample_rate as f32) as usize;
            return Some(VadEvent::ConfirmedSilence { trim_samples });
        }

        let progress = (silence_dur.as_secs_f32() / self.config.silence_timeout.as_secs_f32())
            .clamp(0.0, 1.0);
        let remaining = self.config.silence_timeout.saturating_sub(silence_dur);
        Some(VadEvent::SilenceCountdown {
            remaining_ms: remaining.as_millis() as u64,
            progress,
        })
    }
}

/// Hands-free is the only mode that commits or cancels from a VAD event.
pub fn hands_free_action(hands_free: bool, event: &VadEvent) -> Option<&'static str> {
    if !hands_free {
        return None;
    }
    match event {
        VadEvent::ConfirmedSilence { .. } => Some("stop"),
        VadEvent::InitialTimeout => Some("cancel"),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn loud() -> Vec<f32> {
        vec![0.2; 320]
    }

    fn quiet() -> Vec<f32> {
        vec![0.0001; 320]
    }

    #[test]
    fn silence_after_speech_commits_once() {
        let mut vad = VadDetector::new(VadConfig {
            min_speech_duration: Duration::from_millis(20),
            silence_timeout: Duration::from_millis(40),
            initial_timeout: Duration::from_secs(30),
            ..VadConfig::default()
        });
        assert!(vad.process_frame(&loud()).is_none());
        std::thread::sleep(Duration::from_millis(25));
        assert_eq!(vad.process_frame(&loud()), Some(VadEvent::SpeechStarted));
        // Silence is measured across quiet frames, the way the microphone callback arrives.
        assert!(matches!(
            vad.process_frame(&quiet()),
            Some(VadEvent::SilenceCountdown { .. })
        ));
        std::thread::sleep(Duration::from_millis(45));
        match vad.process_frame(&quiet()) {
            Some(VadEvent::ConfirmedSilence { .. }) => {}
            other => panic!("expected commit, got {other:?}"),
        }
        assert!(vad.process_frame(&quiet()).is_none());
    }

    #[test]
    fn no_speech_times_out_once() {
        let mut vad = VadDetector::new(VadConfig {
            initial_timeout: Duration::from_millis(20),
            silence_timeout: Duration::from_secs(5),
            ..VadConfig::default()
        });
        assert!(vad.process_frame(&quiet()).is_none());
        std::thread::sleep(Duration::from_millis(25));
        assert_eq!(vad.process_frame(&quiet()), Some(VadEvent::InitialTimeout));
        assert!(vad.process_frame(&quiet()).is_none());
    }

    #[test]
    fn hold_to_talk_ignores_vad() {
        let event = VadEvent::ConfirmedSilence { trim_samples: 10 };
        assert_eq!(hands_free_action(false, &event), None);
        assert_eq!(hands_free_action(true, &event), Some("stop"));
    }
}
