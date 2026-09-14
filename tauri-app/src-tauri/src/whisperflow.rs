//! whisperflow.rs — Real-time streaming transcription engine
//!
//! Replicates the whisper-flow pattern: audio chunks arrive via a channel,
//! are buffered into tumbling windows, sent to Groq's Whisper API for
//! transcription, and partial transcripts are emitted back as events.
//!
//! Architecture:
//!   audio chunks → tumbling window buffer → Groq WebSocket → partial transcripts → editor.rs → UI

use serde::{Deserialize, Serialize};
use tauri::{AppHandle, Emitter};
use tokio::sync::mpsc;

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/// Configuration for the streaming engine.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WhisperFlowConfig {
    /// Groq API key (free tier: no credit card required).
    pub api_key: String,
    /// Whisper model to use on Groq (default: whisper-large-v3-turbo).
    pub model: String,
    /// Target sample rate for audio input (default: 16000 Hz).
    pub sample_rate: u32,
    /// Maximum chunk duration in milliseconds before forcing a flush (default: 10000).
    pub max_chunk_ms: u32,
    /// Minimum silence duration in milliseconds to trigger a window break (default: 800).
    pub silence_threshold_ms: u32,
    /// Language hint (default: "en").
    pub language: String,
}

impl Default for WhisperFlowConfig {
    fn default() -> Self {
        Self {
            api_key: String::new(),
            model: "whisper-large-v3-turbo".to_string(),
            sample_rate: 16000,
            max_chunk_ms: 10_000,
            silence_threshold_ms: 800,
            language: "en".to_string(),
        }
    }
}

/// A partial or final transcript chunk emitted by the streaming engine.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TranscriptChunk {
    /// The transcribed text for this chunk.
    pub text: String,
    /// Whether this is a final (committed) transcript or a partial (in-progress) one.
    pub is_final: bool,
    /// Timestamp offset in seconds from the start of the session.
    pub offset_seconds: f64,
    /// Duration of the audio chunk that produced this transcript.
    pub duration_seconds: f64,
}

/// Message sent from the audio capture to the streaming engine.
#[derive(Debug)]
pub enum AudioMessage {
    /// A chunk of 16-bit PCM audio samples (16 kHz mono).
    Chunk(Vec<f32>),
    /// Signal that recording has stopped; flush remaining buffer.
    Flush,
    /// Shut down the streaming engine.
    Shutdown,
}

// ---------------------------------------------------------------------------
// Tumbling Window Buffer
// ---------------------------------------------------------------------------

/// Accumulates audio samples and decides when to flush a window for transcription.
/// Uses a tumbling window strategy: flush on silence detection or max duration.
struct TumblingWindow {
    /// Buffered PCM samples (f32, range -1.0..1.0).
    buffer: Vec<f32>,
    /// Number of samples per millisecond.
    samples_per_ms: f64,
    /// Maximum samples before forced flush.
    max_samples: usize,
    /// Silence threshold in samples.
    silence_samples: usize,
    /// Running sample count since last speech.
    silent_run: usize,
    /// Is the buffer currently in a "speech" state?
    in_speech: bool,
    /// Energy threshold for silence detection (RMS).
    energy_threshold: f32,
}

impl TumblingWindow {
    fn new(config: &WhisperFlowConfig) -> Self {
        let samples_per_ms = config.sample_rate as f64 / 1000.0;
        let max_samples = (samples_per_ms * config.max_chunk_ms as f64) as usize;
        let silence_samples = (samples_per_ms * config.silence_threshold_ms as f64) as usize;

        Self {
            buffer: Vec::with_capacity(max_samples),
            samples_per_ms,
            max_samples,
            silence_samples,
            silent_run: 0,
            in_speech: false,
            energy_threshold: 0.01, // RMS threshold for silence
        }
    }

    /// Push samples into the buffer. Returns `Some(Vec<f32>)` when the window should flush.
    fn push(&mut self, samples: &[f32]) -> Option<Vec<f32>> {
        // Calculate RMS energy of incoming chunk
        let rms = if samples.is_empty() {
            0.0
        } else {
            let sum_sq: f32 = samples.iter().map(|s| s * s).sum();
            (sum_sq / samples.len() as f32).sqrt()
        };

        let is_silent = rms < self.energy_threshold;

        if is_silent {
            self.silent_run += samples.len();
            self.in_speech = false;
        } else {
            self.silent_run = 0;
            self.in_speech = true;
        }

        self.buffer.extend_from_slice(samples);

        // Flush conditions:
        // 1. Buffer exceeds max duration
        // 2. We were in speech and now have a silence gap long enough
        let should_flush = self.buffer.len() >= self.max_samples
            || (!self.in_speech && self.silent_run >= self.silence_samples && self.buffer.len() > 0);

        if should_flush {
            let chunk = std::mem::take(&mut self.buffer);
            self.silent_run = 0;
            Some(chunk)
        } else {
            None
        }
    }

    /// Force-flush whatever is in the buffer.
    fn flush(&mut self) -> Option<Vec<f32>> {
        if self.buffer.is_empty() {
            None
        } else {
            let chunk = std::mem::take(&mut self.buffer);
            self.silent_run = 0;
            Some(chunk)
        }
    }
}

// ---------------------------------------------------------------------------
// Groq API Client
// ---------------------------------------------------------------------------

/// Calls Groq's Whisper API for transcription of an audio chunk.
/// Returns the transcribed text or an error.
async fn transcribe_with_groq(
    config: &WhisperFlowConfig,
    audio_samples: &[f32],
    language: &str,
) -> Result<String, String> {
    // Convert f32 samples to 16-bit PCM bytes
    let pcm_bytes: Vec<u8> = audio_samples
        .iter()
        .flat_map(|&s| {
            let clamped = (s * 32767.0).clamp(-32768.0, 32767.0) as i16;
            clamped.to_le_bytes().to_vec()
        })
        .collect();

    let sample_rate = config.sample_rate;
    let num_channels: u16 = 1;
    let bits_per_sample: u16 = 16;
    let byte_rate = sample_rate * num_channels as u32 * bits_per_sample as u32 / 8;
    let block_align = num_channels * bits_per_sample / 8;
    let data_size = pcm_bytes.len() as u32;

    // Build complete WAV file as bytes (header + PCM data)
    let mut wav = Vec::with_capacity(44 + pcm_bytes.len());
    // RIFF header
    wav.extend_from_slice(b"RIFF");
    wav.extend_from_slice(&(36 + data_size).to_le_bytes());
    wav.extend_from_slice(b"WAVE");
    // fmt subchunk
    wav.extend_from_slice(b"fmt ");
    wav.extend_from_slice(&16u32.to_le_bytes());       // subchunk size
    wav.extend_from_slice(&1u16.to_le_bytes());         // PCM format
    wav.extend_from_slice(&num_channels.to_le_bytes());
    wav.extend_from_slice(&sample_rate.to_le_bytes());
    wav.extend_from_slice(&byte_rate.to_le_bytes());
    wav.extend_from_slice(&block_align.to_le_bytes());
    wav.extend_from_slice(&bits_per_sample.to_le_bytes());
    // data subchunk
    wav.extend_from_slice(b"data");
    wav.extend_from_slice(&data_size.to_le_bytes());
    wav.extend_from_slice(&pcm_bytes);

    // Build multipart request body using raw WAV bytes
    let boundary = "----VoiceFlowBoundary";

    let mut body = Vec::new();
    // File part
    body.extend_from_slice(format!("--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n").as_bytes());
    body.extend_from_slice(&wav);
    body.extend_from_slice(b"\r\n");
    // Model part
    body.extend_from_slice(format!("--{boundary}\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\n{model}\r\n", model = config.model).as_bytes());
    // Language part
    body.extend_from_slice(format!("--{boundary}\r\nContent-Disposition: form-data; name=\"language\"\r\n\r\n{language}\r\n").as_bytes());
    // Response format
    body.extend_from_slice(format!("--{boundary}\r\nContent-Disposition: form-data; name=\"response_format\"\r\n\r\nverbose_json\r\n").as_bytes());
    // End boundary
    body.extend_from_slice(format!("--{boundary}--\r\n").as_bytes());

    let client = reqwest::Client::new();
    let response = client
        .post("https://api.groq.com/openai/v1/audio/transcriptions")
        .header("Authorization", format!("Bearer {}", config.api_key))
        .header("Content-Type", format!("multipart/form-data; boundary={boundary}"))
        .body(body)
        .send()
        .await
        .map_err(|e| format!("HTTP request failed: {e}"))?;

    if !response.status().is_success() {
        let status = response.status();
        let text = response.text().await.unwrap_or_default();
        return Err(format!("Groq API error {status}: {text}"));
    }

    #[derive(Deserialize)]
    struct GroqResponse {
        text: String,
    }

    let resp: GroqResponse = response
        .json()
        .await
        .map_err(|e| format!("Failed to parse response: {e}"))?;

    Ok(resp.text)
}

// ---------------------------------------------------------------------------
// Streaming Engine
// ---------------------------------------------------------------------------

pub struct WhisperFlowEngine {
    config: WhisperFlowConfig,
    window: TumblingWindow,
    app: AppHandle,
    total_samples: u64,
}

impl WhisperFlowEngine {
    pub fn new(config: WhisperFlowConfig, app: AppHandle) -> Self {
        let window = TumblingWindow::new(&config);
        Self {
            config,
            window,
            app,
            total_samples: 0,
        }
    }

    /// Process incoming audio messages. This is the main loop.
    pub async fn run(&mut self, mut rx: mpsc::Receiver<AudioMessage>) {
        while let Some(msg) = rx.recv().await {
            match msg {
                AudioMessage::Chunk(samples) => {
                    self.total_samples += samples.len() as u64;
                    if let Some(chunk) = self.window.push(&samples) {
                        self.transcribe_chunk(chunk).await;
                    }
                }
                AudioMessage::Flush => {
                    if let Some(chunk) = self.window.flush() {
                        self.transcribe_chunk(chunk).await;
                    }
                }
                AudioMessage::Shutdown => {
                    // Flush remaining buffer
                    if let Some(chunk) = self.window.flush() {
                        self.transcribe_chunk(chunk).await;
                    }
                    break;
                }
            }
        }
    }

    async fn transcribe_chunk(&self, samples: Vec<f32>) {
        let duration_secs = samples.len() as f64 / self.config.sample_rate as f64;
        let offset_secs = (self.total_samples as f64 - samples.len() as f64) / self.config.sample_rate as f64;

        // Emit "transcribing" status
        let _ = self.app.emit("whisperflow-status", "transcribing");

        match transcribe_with_groq(&self.config, &samples, &self.config.language).await {
            Ok(text) => {
                let chunk = TranscriptChunk {
                    text,
                    is_final: true,
                    offset_seconds: offset_secs,
                    duration_seconds: duration_secs,
                };
                let _ = self.app.emit("whisperflow-transcript", &chunk);
            }
            Err(e) => {
                let _ = self.app.emit("whisperflow-error", e);
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Public API for Tauri commands
// ---------------------------------------------------------------------------

/// Start the streaming transcription engine.
/// Returns a channel sender for audio chunks.
pub fn start_engine(
    config: WhisperFlowConfig,
    app: AppHandle,
) -> mpsc::Sender<AudioMessage> {
    let (tx, rx) = mpsc::channel(100);

    tokio::spawn(async move {
        let mut engine = WhisperFlowEngine::new(config, app);
        engine.run(rx).await;
    });

    tx
}
