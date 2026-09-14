# VoiceFlow (Tauri)

A macOS menu-bar speech-to-text app built with **Tauri v2** and **Rust**. VoiceFlow captures your microphone and transcribes it locally with [Whisper](https://github.com/ggerganov/whisper.cpp) — **fully offline, no internet, no API key**.

> This Tauri app lives **beside** the existing Swift VoiceFlow app and does not replace it.

## Features

- **Offline Whisper STT** — speech recognition runs entirely on-device via `whisper-rs` (whisper.cpp). No cloud, no API key.
- **Menu-bar app** — `LSUIElement` keeps VoiceFlow out of the Dock; it runs in the background and shows a small window on demand.
- **Global shortcut** — press **⌘⇧V** (Cmd+Shift+V) anywhere to toggle recording.
- **Tray menu** — a tray icon with *Show VoiceFlow*, *Start / Stop Recording*, and *Quit*.
- **In-app controls** — a mic button in the window toggles recording.
- **Settings panel** (gear icon) for:
  - **Language** — pick a language or set *auto* detection.
  - **Auto-copy to clipboard** — automatically copy the transcript when transcription finishes.
  - **Custom model path** — point VoiceFlow at a different Whisper `.bin` model.

## Prerequisites

- **Rust toolchain** — install via [rustup](https://rustup.rs).
- **Node.js 24+** — required by the Tauri CLI / Vite frontend.
- **cmake** — `brew install cmake` (needed to build `whisper-rs` / `whisper.cpp`).
- **Xcode Command Line Tools** — `xcode-select --install`.
- **macOS microphone permission** — grant access when prompted; the app declares `NSMicrophoneUsageDescription` for this.

## Setup

1. Install JS dependencies:

   ```bash
   npm install
   ```

2. Download the Whisper model into `src-tauri/models/`:

   ```bash
   mkdir -p src-tauri/models
   curl -L -o src-tauri/models/ggml-base.bin \
     https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin
   ```

   > The default model is `ggml-base.bin`. VoiceFlow looks for it next to the executable and falls back to `src-tauri/models/`. You can use a different model via the settings panel.

3. Run the app in development:

   ```bash
   npm run tauri dev
   ```

## Usage

- **⌘⇧V** toggles recording from anywhere. Recording also toggles from the tray menu or the in-app mic button.
- Speak, then toggle off — the transcript appears in the window once processing finishes.
- Click the **gear** icon to open settings: choose the recognition **language** (or *auto*), enable **auto-copy to clipboard**, or set a **custom model path**.
- Closing the window hides VoiceFlow to the menu bar rather than quitting. Use the tray menu *Quit VoiceFlow* to exit.

## Build a Release Bundle

```bash
npm run tauri build
```

This produces a macOS `.app` in:

```
src-tauri/target/release/bundle/macos/VoiceFlow.app
```

The bundle target is `app` only, with a minimum system version of macOS 10.15 (Catalina).

## Notes

- Identifier: `com.kennethaman.voiceflow`.
- Audio is captured with `cpal` and resampled to 16 kHz mono before being handed to Whisper (which expects that rate).
- This Tauri implementation is a companion to the existing Swift VoiceFlow app and is designed to coexist with it.
