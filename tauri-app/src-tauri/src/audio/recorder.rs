use anyhow::{Context, Result};
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::Arc;
use std::sync::Mutex;
use std::time::Duration;

pub type AudioChunkCallback = Arc<dyn Fn(&[f32]) + Send + Sync + 'static>;

/// Thread-safe audio recorder using cpal
pub struct AudioRecorder {
    /// Current device (if any)
    device: Mutex<Option<cpal::Device>>,
    /// Collected audio samples (f32, 16kHz mono)
    samples: Arc<Mutex<Vec<f32>>>,
    /// Whether we're currently recording
    is_recording: Arc<AtomicBool>,
    /// The active stream (kept alive while recording)
    stream: Mutex<Option<cpal::Stream>>,
    /// Optional real-time chunk listener for VAD / levels
    chunk_callback: Option<AudioChunkCallback>,
    /// Fractional source position carried across callbacks so 48 kHz → 16 kHz
    /// does not drop a sample at every buffer boundary.
    resample_phase: Arc<Mutex<f64>>,
    /// Loudest sample seen since the stream started, as f32 bits.
    peak: Arc<AtomicU32>,
}

fn note_peak(slot: &AtomicU32, chunk: &[f32]) {
    let mut best = f32::from_bits(slot.load(Ordering::Relaxed));
    for sample in chunk {
        let amp = sample.abs();
        if amp.is_finite() && amp > best {
            best = amp;
        }
    }
    slot.store(best.to_bits(), Ordering::Relaxed);
}

unsafe impl Send for AudioRecorder {}

impl AudioRecorder {
    pub fn new() -> Result<Self> {
        Ok(AudioRecorder {
            device: Mutex::new(None),
            samples: Arc::new(Mutex::new(Vec::new())),
            is_recording: Arc::new(AtomicBool::new(false)),
            stream: Mutex::new(None),
            chunk_callback: None,
            resample_phase: Arc::new(Mutex::new(0.0)),
            peak: Arc::new(AtomicU32::new(0)),
        })
    }

    pub fn set_chunk_callback(&mut self, cb: AudioChunkCallback) {
        self.chunk_callback = Some(cb);
    }

    /// Input whose name matches the settings picker. Falls back at the call site.
    pub fn device_named(name: &str) -> Result<cpal::Device> {
        let host = cpal::default_host();
        let wanted = name.trim();
        for device in host.input_devices().context("Could not list microphones")? {
            if device.name().ok().as_deref().map(str::trim) == Some(wanted) {
                return Ok(device);
            }
        }
        anyhow::bail!("Microphone \"{wanted}\" is not connected")
    }

    /// Copy of the samples captured so far, for a live transcription pass.
    pub fn snapshot(&self) -> Vec<f32> {
        self.samples.lock().unwrap().clone()
    }

    pub fn captured_len(&self) -> usize {
        self.samples.lock().unwrap().len()
    }

    /// Newest samples only, so a live pass does not decode the whole take.
    pub fn snapshot_tail(&self, max_samples: usize) -> Vec<f32> {
        let samples = self.samples.lock().unwrap();
        if max_samples == 0 || samples.len() <= max_samples {
            return samples.clone();
        }
        samples[samples.len() - max_samples..].to_vec()
    }

    /// Loudest absolute sample since `start_recording`. Zero means digital silence.
    pub fn peak(&self) -> f32 {
        f32::from_bits(self.peak.load(Ordering::Relaxed))
    }

    /// Get the default input device
    pub fn default_input_device(&self) -> Result<cpal::Device> {
        let host = cpal::default_host();
        host.default_input_device()
            .context("No default input device found")
    }

    /// List all available input devices
    pub fn list_devices(&self) -> Result<Vec<String>> {
        let host = cpal::default_host();
        let mut devices = Vec::new();
        for d in host.input_devices()? {
            if let Ok(name) = d.name() {
                devices.push(name);
            }
        }
        Ok(devices)
    }

    /// Downmix multi-channel audio to mono and resample to 16kHz via linear interpolation
    fn resample_and_downmix(
        data: &[f32],
        channels: usize,
        source_rate: u32,
        target_rate: u32,
        phase: &mut f64,
    ) -> Vec<f32> {
        if data.is_empty() || channels == 0 {
            return Vec::new();
        }

        // Step 1: Interleaved multi-channel to mono
        let num_frames = data.len() / channels;
        let mut mono = Vec::with_capacity(num_frames);
        for frame_idx in 0..num_frames {
            let offset = frame_idx * channels;
            let mut sum = 0.0f32;
            for ch in 0..channels {
                sum += data[offset + ch];
            }
            mono.push(sum / channels as f32);
        }

        if source_rate == target_rate {
            *phase = 0.0;
            return mono;
        }

        let ratio = source_rate as f64 / target_rate as f64;
        let mut src_pos = *phase;
        let mut resampled = Vec::new();
        let last = mono.len() as f64 - 1.0;
        while src_pos < last {
            let idx = src_pos.floor() as usize;
            let frac = (src_pos - idx as f64) as f32;
            let s0 = mono[idx];
            let s1 = mono[idx + 1];
            resampled.push((s0 + frac * (s1 - s0)).clamp(-1.0, 1.0));
            src_pos += ratio;
        }
        *phase = (src_pos - mono.len() as f64).max(0.0);
        resampled
    }

    /// Start recording from the given device (or default)
    pub fn start_recording(&self, device: Option<cpal::Device>) -> Result<()> {
        // Clear previous samples
        self.samples.lock().unwrap().clear();
        *self.resample_phase.lock().unwrap() = 0.0;
        self.peak.store(0, Ordering::SeqCst);
        self.is_recording.store(true, Ordering::SeqCst);

        let device = match device {
            Some(d) => d,
            None => self.default_input_device()?,
        };

        let config = device
            .default_input_config()
            .context("Failed to get default input config")?;

        let sample_rate = config.sample_rate().0;
        let channels = config.channels() as usize;
        log::info!(
            "Microphone {} at {sample_rate} Hz, {channels} channels, {:?}",
            device.name().unwrap_or_else(|_| "input".into()),
            config.sample_format()
        );

        let samples = Arc::clone(&self.samples);
        let is_recording = Arc::clone(&self.is_recording);
        let callback = self.chunk_callback.clone();
        let phase = Arc::clone(&self.resample_phase);
        let peak = Arc::clone(&self.peak);

        let sample_format = config.sample_format();
        let stream_config: cpal::StreamConfig = config.into();
        let stream = match sample_format {
            cpal::SampleFormat::F32 => {
                let samples = Arc::clone(&samples);
                let is_recording = Arc::clone(&is_recording);
                let callback = callback.clone();
                let phase = Arc::clone(&phase);
                let peak = Arc::clone(&peak);
                device.build_input_stream(
                    &stream_config,
                    move |data: &[f32], _: &cpal::InputCallbackInfo| {
                        if !is_recording.load(Ordering::SeqCst) {
                            return;
                        }
                        let mut phase_guard = phase.lock().unwrap();
                        let resampled = Self::resample_and_downmix(
                            data,
                            channels,
                            sample_rate,
                            16000,
                            &mut phase_guard,
                        );
                        drop(phase_guard);
                        if resampled.is_empty() {
                            return;
                        }
                        note_peak(&peak, &resampled);
                        if let Some(ref cb) = callback {
                            cb(&resampled);
                        }
                        samples.lock().unwrap().extend_from_slice(&resampled);
                    },
                    move |err| {
                        log::error!("Audio input stream error: {}", err);
                    },
                    None,
                )?
            }
            cpal::SampleFormat::I16 => {
                let samples = Arc::clone(&samples);
                let is_recording = Arc::clone(&is_recording);
                let callback = callback.clone();
                let phase = Arc::clone(&phase);
                let peak = Arc::clone(&peak);
                device.build_input_stream(
                    &stream_config,
                    move |data: &[i16], _: &cpal::InputCallbackInfo| {
                        if !is_recording.load(Ordering::SeqCst) {
                            return;
                        }
                        let f32_data: Vec<f32> =
                            data.iter().map(|&sample| sample as f32 / 32768.0).collect();
                        let mut phase_guard = phase.lock().unwrap();
                        let resampled = Self::resample_and_downmix(
                            &f32_data,
                            channels,
                            sample_rate,
                            16000,
                            &mut phase_guard,
                        );
                        drop(phase_guard);
                        if resampled.is_empty() {
                            return;
                        }
                        note_peak(&peak, &resampled);
                        if let Some(ref cb) = callback {
                            cb(&resampled);
                        }
                        samples.lock().unwrap().extend_from_slice(&resampled);
                    },
                    move |err| {
                        log::error!("Audio input stream error: {}", err);
                    },
                    None,
                )?
            }
            other => anyhow::bail!("Unsupported sample format: {:?}", other),
        };

        stream.play()?;
        *self.device.lock().unwrap() = Some(device);
        *self.stream.lock().unwrap() = Some(stream);

        Ok(())
    }

    /// Stop recording and return collected samples
    pub fn stop_recording(&self) -> Vec<f32> {
        self.is_recording.store(false, Ordering::SeqCst);

        // Drop the stream and device reference
        self.stream.lock().unwrap().take();
        self.device.lock().unwrap().take();

        std::thread::sleep(Duration::from_millis(50));

        std::mem::take(&mut *self.samples.lock().unwrap())
    }

    /// Check if currently recording
    pub fn is_recording(&self) -> bool {
        self.is_recording.load(Ordering::SeqCst)
    }
}
