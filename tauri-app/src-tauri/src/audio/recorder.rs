use anyhow::{Context, Result};
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::sync::Mutex;
use std::time::Duration;

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
}

unsafe impl Send for AudioRecorder {}

impl AudioRecorder {
    pub fn new() -> Result<Self> {
        Ok(AudioRecorder {
            device: Mutex::new(None),
            samples: Arc::new(Mutex::new(Vec::new())),
            is_recording: Arc::new(AtomicBool::new(false)),
            stream: Mutex::new(None),
        })
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

    /// Start recording from the given device (or default)
    pub fn start_recording(&self, device: Option<cpal::Device>) -> Result<()> {
        // Clear previous samples
        self.samples.lock().unwrap().clear();
        self.is_recording.store(true, Ordering::SeqCst);

        let device = match device {
            Some(d) => d,
            None => self.default_input_device()?,
        };

        let config = device.default_input_config()
            .context("Failed to get default input config")?;

        let sample_rate = config.sample_rate().0;
        let channels = config.channels() as u16;

        let samples = Arc::clone(&self.samples);
        let is_recording = Arc::clone(&self.is_recording);

        // Build stream based on sample format
        let stream = match config.sample_format() {
            cpal::SampleFormat::F32 => {
                device.build_input_stream(
                    &config.into(),
                    move |data: &[f32], _: &_| {
                        if is_recording.load(Ordering::SeqCst) {
                            // Resample to 16kHz if needed (whisper.cpp expects 16kHz)
                            let target_rate = 16000u32;
                            if sample_rate == target_rate {
                                let mut s = samples.lock().unwrap();
                                s.extend_from_slice(data);
                            } else {
                                // Simple resampling: downsample by skipping samples
                                let ratio = sample_rate as f64 / target_rate as f64;
                                let mut s = samples.lock().unwrap();
                                for i in (0..data.len()).step_by(ratio as usize) {
                                    s.push(data[i]);
                                }
                            }
                        }
                    },
                    move |err| {
                        eprintln!("Input stream error: {}", err);
                    },
                    None,
                )?
            }
            cpal::SampleFormat::I16 => {
                device.build_input_stream(
                    &config.into(),
                    move |data: &[i16], _: &_| {
                        if is_recording.load(Ordering::SeqCst) {
                            let target_rate = 16000u32;
                            let ratio = sample_rate as f64 / target_rate as f64;
                            let mut s = samples.lock().unwrap();
                            for i in (0..data.len()).step_by(ratio as usize) {
                                s.push(data[i] as f32 / 32768.0);
                            }
                        }
                    },
                    move |err| {
                        eprintln!("Input stream error: {}", err);
                    },
                    None,
                )?
            }
            _ => anyhow::bail!("Unsupported sample format: {:?}", config.sample_format()),
        };

        stream.play()?;
        *self.device.lock().unwrap() = Some(device);
        *self.stream.lock().unwrap() = Some(stream);

        Ok(())
    }

    /// Stop recording and return collected samples
    pub fn stop_recording(&self) -> Vec<f32> {
        self.is_recording.store(false, Ordering::SeqCst);

        // Drop the stream and device reference so we can't accidentally restart
        self.stream.lock().unwrap().take();
        self.device.lock().unwrap().take();

        // Give a moment for any pending writes to finish
        std::thread::sleep(Duration::from_millis(50));

        std::mem::take(&mut *self.samples.lock().unwrap())
    }

    /// Check if currently recording
    pub fn is_recording(&self) -> bool {
        self.is_recording.load(Ordering::SeqCst)
    }
}
