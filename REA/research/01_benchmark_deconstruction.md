# Research: Wispr Flow Benchmark Deconstruction

## 1. Overview

Wispr Flow (`wisprflow.ai`) is widely considered the industry benchmark for macOS and Windows voice dictation. This document deconstructs how Wispr Flow works internally—its event interception, audio buffers, inference pipeline, and system text insertion mechanics—providing the exact specifications needed to build WhisperFlow.

---

## 2. Core Functional Pillars

### 2.1 Global Hotkey & Event Interception
* **Mechanism**: Wispr Flow captures global keystrokes using a low-level OS event tap:
  - macOS: `CGEventTapCreate` (`kCGHIDEventTap` or `kCGSessionEventTap`).
  - Windows: `SetWindowsHookEx(WH_KEYBOARD_LL, ...)`.
* **Behavior Model**:
  - **Hold-to-Talk (Push-to-Talk)**: User presses and holds hotkey (default `Fn` or `Option+Space`). Recording begins immediately. Upon key release (if held $> 250\text{ms}$), recording stops and audio is submitted for processing.
  - **Double-Tap Hands-Free**: Two quick presses within $300\text{ms}$ lock dictation into hands-free mode. A subsequent press terminates recording.
  - **Cancel Take (`Esc`)**: Pressing `Escape` at any point during recording or processing aborts the pipeline, drops audio buffers, and leaves the target application unmodified.

### 2.2 Continuous Audio Ring Buffering & Pre-Roll
* **The Problem**: When a user presses a hotkey to speak, they often start speaking before or simultaneously with the key press. A standard capture engine starting *after* key-down drops the initial consonant or syllable ("Send" becomes "end").
* **The Wispr Flow Solution**:
  - The microphone stream is continuously read in the background into an in-memory **circular ring buffer** holding the trailing 300ms–500ms of audio (16kHz 32-bit float mono).
  - When the hotkey triggers, this pre-roll buffer is prepended to the recording buffer, ensuring 100% of speech phonemes are preserved.
  - When idle, memory consumption remains under 200KB for the circular buffer.

### 2.3 Speech Activity Detection (VAD) & Silence Gating
* **Gating Model**:
  - Evaluates audio in small chunk windows (30ms–50ms) using Silero VAD.
  - In hands-free mode, detects trailing silence ($\sim 800\text{ms}$ default) to automatically commit and transcribe without manual intervention.
  - Background noise floor calibration prevents accidental triggers in noisy environments (cafes, offices).

### 2.4 Transcription & Streaming Latency
* **Dual-Inference Pipeline**:
  - **Streaming Mode**: Streams audio in 200ms–500ms chunks to ultra-fast inference APIs (such as Groq Whisper or custom vLLM instances) over HTTP/2 or WebSockets. First partial transcripts arrive within 250ms.
  - **Offline Local Mode**: Invokes whisper.cpp compiled with Apple Silicon Metal acceleration (`GGML_USE_METAL`) or CUDA.
  - **Quantization**: Employs `q5_1` or `q8_0` quantized models (`base.en` or `small.en`) to run inference in $\sim 0.2\times$ real-time factor (RTF).

### 2.5 Contextual Text Polish & Intelligence
* **Post-Processing Layers**:
  - **Layer 1 (Lexical Stripping)**: Fast regex removal of vocal pauses ("um", "uh", "you know", "er", "ah"), stutter repetition ("I I went" $\to$ "I went"), and phonetic punctuation ("period" $\to$ ".", "new paragraph" $\to$ "\n\n").
  - **Layer 2 (Contextual LLM Transformation)**:
    - Queries the focused application to obtain context (e.g. IDE vs Email vs Chat).
    - Uses zero-shot prompt templates to adjust formatting (e.g. converting spoken camelCase/snake_case in code editors, proper capitalization in emails).
    - Custom user dictionary injection (e.g., specific names, company jargon, technical acronyms).

### 2.6 Native Universal Text Injection
* **Text Insertion Strategies**:
  1. **Direct Accessibility API Replacement (`AXUIElement`)**:
     - On macOS, queries `kAXFocusedUIElementAttribute`.
     - Calls `AXUIElementSetValue(element, kAXValueAttribute, newText)` or `AXUIElementPerformAction(..., kAXInsertTextAction)`.
     - *Advantage*: Completely non-destructive to user clipboard, instantaneous, zero keystroke simulation artifacts.
  2. **Safe Clipboard Transaction Fallback**:
     - Used when target applications (e.g., Terminal, electron apps with canvas rendering) reject Accessibility text setting.
     - Saves current pasteboard snapshot.
     - Writes transcription to pasteboard.
     - Simulates synthetic `Cmd+V` / `Ctrl+V`.
     - Waits for target application event queue to drain ($\sim 35\text{ms}$), then restores original pasteboard contents.

### 2.7 Floating HUD Overlay UX
* **Visual Presentation**:
  - A compact, pill-shaped HUD that floats above the cursor or sits unobtrusively at the top/bottom of the active screen.
  - Non-activating window (`NSPanel` with `NSWindowStyleMaskNonactivatingPanel`), ensuring the target application never loses focus.
  - Real-time sound wave visualizer responding directly to input amplitude.
  - Four visual states: `Listening` (glowing border), `Processing` (pulsing indicator), `Done` (green checkmark flash), and `Canceled` (fade out).
