# Research: Codebase Audit & Gap Analysis

## 1. Overview

This document presents a comprehensive audit of the existing VoiceFlow codebase across both its implementations:
1. **macOS Native Stack**: Swift 6, whisper.cpp, AppKit/SwiftUI in [`VoiceFlow/Sources/`](file:///Users/kennethaman/VoiceFlow/VoiceFlow/Sources).
2. **Cross-Platform Stack**: Tauri v2, Rust, whisper-rs, React in [`tauri-app/`](file:///Users/kennethaman/VoiceFlow/tauri-app).

---

## 2. Component-by-Component Audit

### 2.1 Audio Capture & Buffering

| Implementation | File Location | Current Architecture | Deficiencies & Gaps |
| :--- | :--- | :--- | :--- |
| **Swift (macOS)** | [`AudioCaptureEngine.swift`](file:///Users/kennethaman/VoiceFlow/VoiceFlow/Sources/Audio/AudioCaptureEngine.swift) | Uses `AVAudioEngine` input node with `installTap`. Captures 16kHz mono buffer. | **No pre-roll buffer**: Begins recording only after tap starts, missing initial phonemes when user starts speaking right as hotkey is pressed. |
| **Rust (Tauri)** | [`recorder.rs`](file:///Users/kennethaman/VoiceFlow/tauri-app/src-tauri/src/audio/recorder.rs) | Uses `cpal` to capture audio input stream into a shared `Arc<Mutex<Vec<f32>>>`. | No circular ring buffer before record trigger; allocations during capture loop; lacks automatic sample rate conversion for hardware not supporting 16kHz natively. |

### 2.2 Voice Activity Detection (VAD)

| Implementation | File Location | Current Architecture | Deficiencies & Gaps |
| :--- | :--- | :--- | :--- |
| **Swift (macOS)** | [`VoiceActivityDetector.swift`](file:///Users/kennethaman/VoiceFlow/VoiceFlow/Sources/Audio/VoiceActivityDetector.swift) | Energy/RMS thresholding with sliding window. | Prone to false negatives on quiet speech and false positives on typing/ambient noise. Needs Silero VAD v5 ONNX integration. |
| **Rust (Tauri)** | [`vad.rs`](file:///Users/kennethaman/VoiceFlow/tauri-app/src-tauri/src/audio/vad.rs) | Windowed energy detector emitting `VadEvent`. | Lacks neural VAD; threshold is static rather than adapting to background room noise floor. |

### 2.3 Speech-to-Text Engines

| Implementation | File Location | Current Architecture | Deficiencies & Gaps |
| :--- | :--- | :--- | :--- |
| **Swift (macOS)** | [`WhisperEngine.swift`](file:///Users/kennethaman/VoiceFlow/VoiceFlow/Sources/Speech/WhisperEngine.swift) | Direct C-API wrapper for `whisper.cpp` via SwiftPM `import whisper`. | Well-structured serialized access; does not yet support speculative partial chunking during active recording. |
| **Rust (Tauri)** | [`transcriber.rs`](file:///Users/kennethaman/VoiceFlow/tauri-app/src-tauri/src/speech/transcriber.rs) | Uses `whisper_rs::WhisperContext` with greedy decoding. | Does not stream interim partials to frontend; model load blocks until completed on first run. |

### 2.4 Text Post-Processing & Intelligence

| Implementation | File Location | Current Architecture | Deficiencies & Gaps |
| :--- | :--- | :--- | :--- |
| **Swift (macOS)** | [`TextCleanupManager.swift`](file:///Users/kennethaman/VoiceFlow/VoiceFlow/Sources/Cleanup/TextCleanupManager.swift) | Optional Ollama client integration + regex `TextPostProcessor`. | Ollama network roundtrip introduces 400ms–1200ms latency. Needs embedded quantized GGUF or two-tier architecture (instant regex + async LLM polish). |
| **Rust (Tauri)** | [`cleaner.rs`](file:///Users/kennethaman/VoiceFlow/tauri-app/src-tauri/src/cleanup/cleaner.rs) | Dynamic library loading of `llama.cpp` (`libloading`) for GGUF models. | High initialization overhead and brittle dynamic library discovery. Needs static linking or unified client interface. |

### 2.5 Text Injection & Pasting

| Implementation | File Location | Current Architecture | Deficiencies & Gaps |
| :--- | :--- | :--- | :--- |
| **Swift (macOS)** | [`TextPaster.swift`](file:///Users/kennethaman/VoiceFlow/VoiceFlow/Sources/Hotkey/TextPaster.swift) | Saves clipboard, sets string, posts synthetic `Cmd+V` CGEvent, restores clipboard after delay. | Keystroke simulation (`Cmd+V`) occasionally misses if the target application takes time to react or is in a modal state. Missing direct `AXUIElementSetValue` as primary insertion strategy. |
| **Rust (Tauri)** | [`paster.rs`](file:///Users/kennethaman/VoiceFlow/tauri-app/src-tauri/src/input/paster.rs) | Uses `enigo` / system clipboard paste simulation. | Subject to OS clipboard race conditions on Windows/Linux; clipboard restoration timer can conflict with fast user actions. |

### 2.6 Global Hotkey Coordination

| Implementation | File Location | Current Architecture | Deficiencies & Gaps |
| :--- | :--- | :--- | :--- |
| **Swift (macOS)** | [`HotkeyMonitor.swift`](file:///Users/kennethaman/VoiceFlow/VoiceFlow/Sources/Hotkey/HotkeyMonitor.swift) | Uses `NSEvent.addGlobalMonitorForEvents` and local monitor. | Global monitor does not intercept modifier-only hold-to-talk with microsecond accuracy; requires `CGEventTap` for true system-wide edge detection. |
| **Rust (Tauri)** | [`coordinator.rs`](file:///Users/kennethaman/VoiceFlow/tauri-app/src-tauri/src/input/coordinator.rs) | Solid state machine (`ShortcutCoordinator`) supporting `StartPushToTalk`, `StartHandsFree`, `StopAndTranscribe`, `Cancel`. | Well-designed edge state machine; needs wiring to continuous audio pre-roll buffer. |

---

## 3. Prioritized Engineering Lift Requirements

To bring WhisperFlow to parity with the Wispr Flow benchmark:

1. **Audio Pre-Buffer Lift**: Implement a dedicated `RingBuffer` component in [`REA/execution/audio/`](file:///Users/kennethaman/VoiceFlow/REA/execution/audio) storing 500ms of uncompressed 16kHz audio.
2. **Universal Direct AX Injector**: Build a multi-strategy text injector (`AXUIElement` primary $\to$ synthetic keystroke fallback) in [`REA/execution/injection/`](file:///Users/kennethaman/VoiceFlow/REA/execution/injection).
3. **Optimized Dual Speech Dispatcher**: Build a unified engine interface in [`REA/execution/speech/`](file:///Users/kennethaman/VoiceFlow/REA/execution/speech) capable of seamless switching between local Metal whisper.cpp and streaming Groq Whisper.
4. **Two-Tier Text Polish Engine**: Implement ultra-fast L1 lexical stripping (<2ms) paired with an optional L2 context LLM in [`REA/execution/cleanup/`](file:///Users/kennethaman/VoiceFlow/REA/execution/cleanup).
