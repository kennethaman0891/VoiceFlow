# Architecture: Component Interfaces & Contracts

## 1. Overview

This document specifies the exact interface contracts, data models, and error boundaries for all subsystems within WhisperFlow. These definitions provide the blueprint for both the Swift native implementation and the Rust/Tauri cross-platform implementation.

---

## 2. Core Data Models

### 2.1 Audio Packet & Pre-Buffer

```rust
/// Contiguous 16kHz mono audio frame.
pub struct AudioBuffer {
    pub sample_rate: u32,       // Always 16,000 Hz
    pub channels: u16,          // Always 1 (mono)
    pub samples: Vec<f32>,      // Normalized f32 audio samples [-1.0, 1.0]
    pub duration_ms: u64,       // Buffer length in milliseconds
}
```

```swift
/// Contiguous 16kHz mono audio frame in Swift.
public struct AudioBuffer: Sendable {
    public let sampleRate: Double     // 16000.0
    public let samples: [Float]       // Normalized Float samples
    public let duration: TimeInterval // samples.count / 16000.0
}
```

### 2.2 Target Application Context

```rust
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AppCategory {
    CodeEditor,       // VS Code, Xcode, IntelliJ
    ChatAndMessaging, // Slack, Discord, Messages
    Email,            // Mail, Outlook
    Browser,          // Chrome, Safari, Firefox
    Terminal,         // Terminal, iTerm2, Alacritty
    DocumentEditor,   // Notion, Obsidian, Word
    Generic,
}

#[derive(Debug, Clone)]
pub struct TargetAppContext {
    pub process_id: i32,
    pub bundle_id: String,
    pub app_name: String,
    pub category: AppCategory,
    pub supports_accessibility_value: bool,
}
```

### 2.3 Post-Processing Request & Result

```rust
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CleanupMode {
    Verbatim,       // No post-processing applied
    RemoveFillers,  // Strip um, uh, like, etc.
    FixGrammar,     // Punctuation and grammatical polish
    Professional,   // Formal business phrasing
    Concise,        // Condensed summary-style prose
}

#[derive(Debug, Clone)]
pub struct CleanupResult {
    pub original: String,
    pub cleaned: String,
    pub mode: CleanupMode,
    pub duration_ms: u64,
}
```

---

## 3. Subsystem Interface Protocols

### 3.1 Audio Capture & Ring Buffer Protocol

```swift
public protocol AudioCaptureProviding: AnyObject, Sendable {
    /// Starts background monitoring to populate the continuous 500ms pre-roll buffer.
    func startMonitoring() async throws

    /// Begins recording an active utterance, prepending the pre-roll buffer.
    func beginRecordingSession() async throws

    /// Stops recording and returns the complete stitched 16kHz mono audio buffer.
    func stopRecordingSession() async -> AudioBuffer

    /// Cancels recording and drops the active session without transcribing.
    func cancelRecordingSession() async

    /// Stream of current RMS audio power level for waveform visualizer [0.0 - 1.0].
    var audioLevelPublisher: AnyPublisher<Float, Never> { get }
}
```

### 3.2 Speech Inference Protocol

```rust
pub trait SpeechEngine: Send + Sync {
    /// Transcribe 16kHz mono audio samples.
    fn transcribe(&self, buffer: &AudioBuffer, language: Option<&str>) -> anyhow::Result<String>;

    /// Returns whether this engine runs locally or over the network.
    fn is_local(&self) -> bool;

    /// Engine identifier for telemetry and debugging.
    fn engine_id(&self) -> &'static str;
}
```

### 3.3 Text Injection Protocol

```swift
public protocol TextInjecting: Sendable {
    /// Injects text into the frontmost application.
    /// Returns the strategy employed and success status.
    func inject(
        text: String,
        targetContext: TargetAppContext
    ) async -> InjectionOutcome
}

public enum InjectionOutcome: Equatable, Sendable {
    case directAccessibilitySucceeded
    case clipboardPastedSucceeded(restoredOriginalClipboard: Bool)
    case cancelled
    case failed(reason: String)
}
```
