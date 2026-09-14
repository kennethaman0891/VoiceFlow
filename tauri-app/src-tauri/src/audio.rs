use std::sync::atomic::Ordering;
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::Duration;

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{SampleFormat, Stream};

use crate::state::AppState;

fn push_mono(samples: &Arc<Mutex<Vec<f32>>>, frame: f32) {
    samples.lock().unwrap().push(frame);
}

/// Start capturing microphone audio into the shared sample buffer.
///
/// The cpal `Stream` is **not** `Send`, so we cannot move a built stream into
/// another thread. Instead we move only `Send` values (the device + config) into
/// a dedicated thread and build the stream there. It stays alive until
/// `stop_flag` is set, then is dropped to stop capture.
pub fn start_capture(state: &AppState) -> Result<(), String> {
    let host = cpal::default_host();
    let device = host
        .default_input_device()
        .ok_or_else(|| "No input device found".to_string())?;
    let supported = device
        .default_input_config()
        .map_err(|e| format!("No default input config: {}", e))?;

    let sample_rate = supported.sample_rate().0;
    let channels = supported.channels() as usize;
    *state.capture_rate.lock().unwrap() = sample_rate;
    state.samples.lock().unwrap().clear();
    state.stop_flag.store(false, Ordering::SeqCst);

    let samples = state.samples.clone();
    let stop_flag = state.stop_flag.clone();
    let (tx, rx) = mpsc::channel::<Result<(), String>>();

    let handle: JoinHandle<()> = thread::spawn(move || {
        let err_fn = |e: cpal::StreamError| eprintln!("audio error: {}", e);

        let stream: Stream = match supported.sample_format() {
            SampleFormat::F32 => {
                let cfg: cpal::StreamConfig = supported.into();
                match device.build_input_stream(
                    &cfg,
                    move |data: &[f32], _: &cpal::InputCallbackInfo| {
                        if channels == 1 {
                            for &s in data {
                                push_mono(&samples, s);
                            }
                        } else {
                            for chunk in data.chunks(channels) {
                                let avg = chunk.iter().sum::<f32>() / channels as f32;
                                push_mono(&samples, avg);
                            }
                        }
                    },
                    err_fn,
                    None,
                ) {
                    Ok(s) => s,
                    Err(e) => {
                        let _ = tx.send(Err(format!("build stream: {}", e)));
                        return;
                    }
                }
            }
            SampleFormat::I16 => {
                let cfg: cpal::StreamConfig = supported.into();
                match device.build_input_stream(
                    &cfg,
                    move |data: &[i16], _: &cpal::InputCallbackInfo| {
                        if channels == 1 {
                            for &s in data {
                                push_mono(&samples, s as f32 / i16::MAX as f32);
                            }
                        } else {
                            for chunk in data.chunks(channels) {
                                let avg = chunk.iter().map(|&x| x as f32).sum::<f32>()
                                    / channels as f32
                                    / i16::MAX as f32;
                                push_mono(&samples, avg);
                            }
                        }
                    },
                    err_fn,
                    None,
                ) {
                    Ok(s) => s,
                    Err(e) => {
                        let _ = tx.send(Err(format!("build stream: {}", e)));
                        return;
                    }
                }
            }
            fmt => {
                let _ = tx.send(Err(format!("Unsupported sample format: {:?}", fmt)));
                return;
            }
        };

        if let Err(e) = stream.play() {
            let _ = tx.send(Err(format!("play stream: {}", e)));
            return;
        }
        let _ = tx.send(Ok(()));

        while !stop_flag.load(Ordering::SeqCst) {
            thread::sleep(Duration::from_millis(50));
        }
        drop(stream);
    });

    // Wait for the stream to build (or fail) before reporting success.
    match rx.recv_timeout(Duration::from_secs(5)) {
        Ok(Ok(())) => {
            *state.capture_thread.lock().unwrap() = Some(handle);
            Ok(())
        }
        Ok(Err(e)) => {
            let _ = handle.join();
            Err(e)
        }
        Err(_) => {
            // Timed out waiting — assume it is still building; keep the handle.
            *state.capture_thread.lock().unwrap() = Some(handle);
            Ok(())
        }
    }
}

/// Signal the capture thread to stop, wait for it to finish, and return the
/// recorded (mono) samples.
pub fn stop_capture(state: &AppState) -> Vec<f32> {
    state.stop_flag.store(true, Ordering::SeqCst);
    if let Some(h) = state.capture_thread.lock().unwrap().take() {
        let _ = h.join();
    }
    let mut guard = state.samples.lock().unwrap();
    std::mem::take(&mut *guard)
}
