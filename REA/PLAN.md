# Master Plan: WhisperFlow Development via REA

## 1. Executive Summary

WhisperFlow is a system-wide, privacy-first voice dictation and intelligence utility. It allows users to dictate into any text input on macOS, Windows, and Linux via a global hotkey, executing low-latency speech-to-text with Whisper models, smart LLM text formatting, and direct accessibility-based text injection.

This plan details the full development lifecycle executed under the **REA (Research, Execute, Assess)** methodology. All work, lifted code, and verification artifacts are contained strictly within [`REA/`](file:///Users/kennethaman/VoiceFlow/REA).

---

## 2. REA Lifecycle Breakdown

### Phase 1: Research (R)
- **R1. Benchmark Deconstruction**: Extract operational mechanics of Wispr Flow (audio ring buffering, event tap, direct AX injection, speculative streaming, smart LLM prompt structure). See [research/01_benchmark_deconstruction.md](file:///Users/kennethaman/VoiceFlow/REA/research/01_benchmark_deconstruction.md).
- **R2. Baseline Codebase Audit**: Evaluate existing code in [`VoiceFlow/Sources/`](file:///Users/kennethaman/VoiceFlow/VoiceFlow/Sources) and [`tauri-app/src-tauri/`](file:///Users/kennethaman/VoiceFlow/tauri-app/src-tauri). Identify architectural bottlenecks, thread-blocking issues, and missing capabilities. See [research/02_codebase_audit.md](file:///Users/kennethaman/VoiceFlow/REA/research/02_codebase_audit.md).
- **R3. Latency Budget Definition**: Map out latency from keydown to final text insertion across local and cloud backends ($p50 < 480\text{ms}$ cloud / $<750\text{ms}$ local). See [research/03_latency_budget.md](file:///Users/kennethaman/VoiceFlow/REA/research/03_latency_budget.md).

### Phase 2: Execute (E)
- **E1. System Architecture Specification**: Formalize decoupled subsystem pipelines, state machines, and zero-copy audio buffers. See [architecture/system_architecture.md](file:///Users/kennethaman/VoiceFlow/REA/architecture/system_architecture.md).
- **E2. Interface Contracts**: Standardize Rust and Swift data structures, error types, and IPC messages. See [architecture/component_interfaces.md](file:///Users/kennethaman/VoiceFlow/REA/architecture/component_interfaces.md).
- **E3. Code Lifting & Implementation Modules**:
  - `audio/`: Pre-speech circular ring buffer (500ms) + Silero VAD gating.
  - `speech/`: Optimized Whisper inference engine (Metal/CoreML/cuBLAS) + Groq streaming adapter.
  - `cleanup/`: Two-tier post-processing (L1 regex filler removal + L2 context-aware prompt formatter).
  - `injection/`: Native accessibility text injector (`AXUIElement` / `SendInput` with safe clipboard restoration).
  - `coordinator/`: Global shortcut and recording state machine (hold-to-talk, double-tap hands-free, escape cancel).

### Phase 3: Assess (A)
- **A1. Automated Latency Profiling**: Measure timestamp intervals between user speech completion and text insertion.
- **A2. Transcription Accuracy & WER**: Validate against standardized test datasets (LibriSpeech clean samples, WER $< 4.5\%$).
- **A3. Universal App Compatibility**: Verify text injection in Slack, VS Code, Chrome, Terminal/iTerm2, Apple Notes, Notion, and Discord.
- **A4. Clipboard & System Safety**: 100% clipboard preservation guarantee without race conditions or clipboard clobbering. See [assessment/benchmarks.md](file:///Users/kennethaman/VoiceFlow/REA/assessment/benchmarks.md).

---

## 3. Implementation Sprint Roadmap

| Sprint | Focus Area | Deliverables | Status |
| :--- | :--- | :--- | :--- |
| **Sprint 1** | **Audio & VAD Foundation** | 500ms circular ring buffer, continuous background audio capture, Silero VAD v5 integration, 16kHz resampling. | 🛠️ In Progress |
| **Sprint 2** | **Speech-to-Text Pipeline** | Metal/CUDA whisper.cpp acceleration, quantized `ggml-base-q5_1` setup, streaming Groq API fallback, speculative chunking. | 📋 Planned |
| **Sprint 3** | **Injection & App Context** | Direct macOS `AXUIElement` text replacement, Windows `SendInput`, safe clipboard snapshot/restore, frontmost app PID inspector. | 📋 Planned |
| **Sprint 4** | **Intelligence & UX Overlay** | Tier-1 filler stripping (<2ms), Tier-2 context LLM formatting, floating pill HUD, reactive audio waveform, sound effects. | 📋 Planned |

---

## 4. Acceptance Criteria & Quality Gates

1. **End-to-End Latency**:
   - Cloud pipeline: Speech stop to text inserted in $<500\text{ms}$ ($p50$).
   - Local pipeline: Speech stop to text inserted in $<800\text{ms}$ ($p50$ on Apple Silicon M-series).
2. **Text Accuracy**:
   - Clean dictation WER $\le 4.5\%$.
   - Filler word removal rate $\ge 98\%$ on "um", "uh", "you know", "like".
3. **Safety & Stability**:
   - Clipboard content pre-dictation strictly preserved on $100\%$ of paste attempts.
   - Zero memory leaks over 24-hour idle background operation ($<120\text{MB}$ resident set size).
