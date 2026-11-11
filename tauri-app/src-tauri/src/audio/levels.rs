//! Voice-band level meter for the floating pill.
//!
//! Sixteen log-spaced bands from 400 Hz to 4 kHz, on 32 ms of 16 kHz audio.
//! The scale is chosen so a normal speaking voice clears the 3 px bar floor
//! and room tone stays on it.

use std::time::{Duration, Instant};

const FRAME: usize = 512;
const BANDS: usize = 16;
const SAMPLE_RATE: f32 = 16_000.0;
const DB_MIN: f32 = -55.0;
const DB_MAX: f32 = -8.0;
const GAIN: f32 = 1.3;
const CURVE: f32 = 0.7;
const EMIT_GAP: Duration = Duration::from_millis(33);

pub struct LevelMeter {
    pending: Vec<f32>,
    last_emit: Option<Instant>,
}

impl LevelMeter {
    pub fn new() -> Self {
        Self {
            pending: Vec::with_capacity(FRAME * 2),
            last_emit: None,
        }
    }

    /// Fold a 16 kHz mono chunk. Returns a fresh 16-band frame at most
    /// every 33 ms, dropping older frames so the meter does not lag.
    pub fn push(&mut self, chunk: &[f32]) -> Option<[f32; BANDS]> {
        if chunk.is_empty() {
            return None;
        }
        self.pending.extend_from_slice(chunk);

        let mut latest: Option<[f32; BANDS]> = None;
        while self.pending.len() >= FRAME {
            let now = Instant::now();
            let due = self
                .last_emit
                .map(|t| now.duration_since(t) >= EMIT_GAP)
                .unwrap_or(true);
            if !due {
                let drop_n = (self.pending.len() / FRAME) * FRAME;
                self.pending.drain(..drop_n);
                break;
            }
            let frame: Vec<f32> = self.pending.drain(..FRAME).collect();
            latest = Some(analyze_frame(&frame));
            self.last_emit = Some(now);
        }
        latest
    }
}

impl Default for LevelMeter {
    fn default() -> Self {
        Self::new()
    }
}

fn band_freq(index: usize) -> f32 {
    let t = index as f32 / (BANDS as f32 - 1.0);
    400.0 * (10.0_f32).powf(t)
}

fn analyze_frame(frame: &[f32]) -> [f32; BANDS] {
    let mut bands = [0.0_f32; BANDS];
    for (i, band) in bands.iter_mut().enumerate() {
        let mag = goertzel_magnitude(frame, band_freq(i));
        let normalized = mag * 2.0 / FRAME as f32;
        let db = 20.0 * (normalized + 1.0e-9).log10();
        let t = ((db - DB_MIN) / (DB_MAX - DB_MIN)).clamp(0.0, 1.0);
        *band = (t * GAIN).clamp(0.0, 1.0).powf(CURVE);
    }
    let src = bands;
    for i in 0..BANDS {
        let prev = if i == 0 { src[0] } else { src[i - 1] };
        let next = if i + 1 == BANDS { src[i] } else { src[i + 1] };
        bands[i] = 0.25 * prev + 0.5 * src[i] + 0.25 * next;
    }
    // A normal laptop mic sits well below the pure-tone test level. Lift every
    // band from broadband energy so speech does not render as a row of dots.
    let rms = (frame.iter().map(|sample| sample * sample).sum::<f32>() / frame.len() as f32).sqrt();
    let rms_db = 20.0 * (rms + 1.0e-9).log10();
    let presence = ((rms_db + 48.0) / 30.0).clamp(0.0, 1.0);
    if presence > 0.0 {
        let lift = presence * 0.55;
        for band in &mut bands {
            *band = (*band + lift).clamp(0.0, 1.0);
        }
    }
    bands
}

fn goertzel_magnitude(frame: &[f32], freq: f32) -> f32 {
    let n = frame.len() as f32;
    let k = (freq * n / SAMPLE_RATE).round();
    let omega = std::f32::consts::TAU * k / n;
    let coeff = 2.0 * omega.cos();
    let mut s1 = 0.0_f32;
    let mut s2 = 0.0_f32;
    let denom = (n - 1.0).max(1.0);
    for (i, &sample) in frame.iter().enumerate() {
        let window = 0.5 * (1.0 - (std::f32::consts::TAU * i as f32 / denom).cos());
        let s0 = sample * window + coeff * s1 - s2;
        s2 = s1;
        s1 = s0;
    }
    let power = s1 * s1 + s2 * s2 - coeff * s1 * s2;
    power.max(0.0).sqrt()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tone(freq: f32, amp: f32) -> Vec<f32> {
        (0..FRAME)
            .map(|i| amp * (std::f32::consts::TAU * freq * i as f32 / SAMPLE_RATE).sin())
            .collect()
    }

    #[test]
    fn silence_stays_on_the_floor() {
        let bands = analyze_frame(&vec![0.0; FRAME]);
        assert!(bands.iter().all(|b| *b < 0.02), "silence bands: {bands:?}");
    }

    #[test]
    fn a_quiet_speaking_tone_still_leaves_the_floor() {
        let bands = analyze_frame(&tone(1_000.0, 0.04));
        let peak = bands.iter().cloned().fold(0.0_f32, f32::max);
        assert!(
            peak > 0.2,
            "quiet speech should move the meter, peak {peak}, bands {bands:?}"
        );
    }

    #[test]
    fn a_speaking_tone_moves_its_band() {
        let bands = analyze_frame(&tone(1_000.0, 0.22));
        let peak = bands
            .iter()
            .cloned()
            .fold(0.0_f32, f32::max);
        let low = bands[0];
        assert!(
            peak > 0.28,
            "1 kHz speech-level tone should clear the floor, peak {peak}, bands {bands:?}"
        );
        assert!(
            peak > low + 0.12,
            "energy should sit in the vocal bands, not the bottom one: {bands:?}"
        );
        let pixels = 3.0 + peak.powf(0.7) * 15.0;
        assert!(
            pixels > 8.0,
            "bar travel should be several pixels, got {pixels}"
        );
    }

    #[test]
    fn push_emits_one_frame_per_window() {
        let mut meter = LevelMeter::new();
        assert!(meter.push(&tone(800.0, 0.2)[..256]).is_none());
        let frame = meter.push(&tone(800.0, 0.2)[..256]).expect("full window");
        assert_eq!(frame.len(), BANDS);
        assert!(frame.iter().any(|b| *b > 0.1));
    }
}
