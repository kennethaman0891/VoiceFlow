# VoiceFlow v2

A privacy-first, offline voice dictation app built with Tauri 2. Runs 100% locally with zero cloud dependency — no Ollama server, no API keys, no internet required.

## Features

- **Push-to-Talk Dictation** — Hold Ctrl+Space to record, release to transcribe and paste
- **Offline Speech-to-Text** — whisper.cpp running locally (medium.en model)
- **Text Cleanup** — Optional LLM-powered cleanup with Qwen 3.5 0.8B (removes fillers, adds punctuation)
- **Auto-Paste** — Automatically pastes cleaned text into your active application
- **Menu Bar App** — Lightweight system tray icon, no dock presence
- **Zero Network Activity** — Models downloaded once, then fully offline

## Architecture

```
voiceflow/
├── src-tauri/                 # Rust backend
│   ├── src/
│   │   ├── main.rs           # Tauri entry point & commands
│   │   ├── state.rs          # Shared app state
│   │   ├── audio/            # cpal-based microphone capture
│   │   ├── speech/           # whisper.cpp FFI wrapper
│   │   ├── cleanup/          # llama.cpp FFI wrapper (optional)
│   │   ├── input/            # Global hotkey + clipboard paste
│   │   └── model/            # Model download & caching
│   ├── tauri.conf.json       # Tauri v2 configuration
│   └── capabilities/         # Permission definitions
├── src/                      # React/TypeScript frontend
│   ├── main.tsx              # Entry point
│   ├── App.tsx               # Main component
│   ├── components/           # React components
│   │   ├── MenuBar.tsx
│   │   ├── RecordingOverlay.tsx
│   │   ├── TranscriptView.tsx
│   │   ├── SettingsPanel.tsx
│   │   └── Onboarding.tsx
│   └── styles.css            # Complete stylesheet
└── public/
    └── favicon.svg
```

## Tech Stack

- **Framework**: Tauri v2 (Rust + WebView)
- **Speech-to-Text**: whisper.cpp (FFI bindings)
- **Text Cleanup**: llama.cpp (FFI bindings, optional)
- **Audio Capture**: cpal crate
- **Frontend**: React 18 + TypeScript + Vite
- **Global Hotkeys**: tauri-plugin-global-shortcut
- **Clipboard**: arboard crate

## Requirements

- macOS 13.0+ / Windows 10+ / Linux (Ubuntu 22.04+)
- Rust toolchain (1.77+)
- Node.js 18+
- For whisper.cpp GPU acceleration: Metal (macOS) or Vulkan (Windows/Linux)

## Installation

```bash
# Install system dependencies (macOS)
brew install libsndfile

# Install npm dependencies
npm install

# Install Tauri CLI
npm install -g @tauri-apps/cli
```

## Development

```bash
# Start development server
npm run tauri dev

# Build for production
npm run tauri build
```

## Usage

1. **First launch**: The app will check for required models and guide you through downloads
2. **Dictate**: Press and hold `Ctrl+Space` anywhere on your system, or click the mic widget
3. **Release**: The transcribed (and optionally cleaned) text is automatically pasted
4. **Settings**: Click the gear icon to configure language, models, and auto-paste

### Mic Widget

The app includes a dedicated floating mic widget you can drag to any position on screen:

- Click to start/stop dictation
- Drag to reposition the widget
- Double-click to reset to default position
- Keyboard shortcut: `Space` to start recording (when idle)
- Position is saved between sessions

The widget provides visual feedback when recording and can be moved anywhere on screen for convenient access.

## Model Management

Models are stored in:
- **macOS**: `~/Library/Application Support/VoiceFlow/models/`
- **Linux**: `~/.local/share/voiceflow/models/`
- **Windows**: `%APPDATA%\VoiceFlow\models\`

Available models:
| Model | Size | Description |
|-------|------|-------------|
| Tiny | 75 MB | Fastest, lower accuracy |
| Base | 148 MB | Good balance |
| Small | 488 MB | Better accuracy |
| Medium | 1.5 GB | Best accuracy (default) |

## Privacy

VoiceFlow is designed for maximum privacy:
- All processing happens locally on your device
- No telemetry, analytics, or crash reporting
- No data ever leaves your machine after initial model download
- Zero network activity during normal operation

## Building from Source

### Prerequisites

```bash
# macOS
brew install rustup libsndfile

# Ubuntu/Debian
sudo apt-get install -y build-essential curl libssl1.1 libasound2-dev

# Windows
# Install Rust via rustup, ensure Visual Studio Build Tools installed
```

### Steps

```bash
# Clone and enter directory
cd tauri-app

# Install frontend dependencies
npm install

# Run in development mode
npm run tauri dev

# Build for distribution
npm run tauri build
```

## License

MIT
