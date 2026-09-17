# VoiceFlow

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE) [![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE) [![License: GPL v3](https://img.shields.io/badge/License-GPL_v3-blue)](LICENSE) [![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Windows%20%7C%20Linux-lightgrey.svg)](#) [![Language](https://img.shields.io/badge/language-Swift%20%7C%20Rust%20%7C%20JavaScript-orange.svg)](#) [![GitHub stars](https://img.shields.io/github/stars/kennethaman0891/VoiceFlow?style=social)](https://github.com/kennethaman0891/VoiceFlow/stargazers) [![GitHub forks](https://img.shields.io/github/forks/kennethaman0891/VoiceFlow?style=social)](https://github.com/kennethaman0891/VoiceFlow/network/members)

<div align="center">

**Privacy-first offline speech-to-text & voice dictation for macOS, Windows & Linux.** Runs Whisper entirely on-device — no cloud, no API keys, no telemetry.

[**Download**](#quick-start) · [**Browser Demo**](#browser-demo) · [**Embed Widget**](#embed-on-your-own-site) · [**Docker Setup**](#docker--full-backend-stack--dev-environment) · [**GitHub**](https://github.com/kennethaman0891/VoiceFlow)

</div>

![VoiceFlow UI](voiceflow-ui.png)
![VoiceFlow Mic](voiceflow-mic-final.png)
![VoiceFlow Showcase](voiceflow-mic-showcase.png)

---

## What is VoiceFlow?

VoiceFlow is an **open-source, offline voice dictation app** that transcribes your speech to text using OpenAI's Whisper model — running **100% locally on your device**. No internet required. No data sent to the cloud. No API keys. No subscriptions.

Built for **developers, writers, journalists, and privacy-conscious users** who want fast, accurate speech-to-text without compromising their data.

### Why Choose VoiceFlow?

| Feature | VoiceFlow | Cloud Alternatives (Google, Otter.ai, etc.) |
|---------|-----------|---------------------------------------------|
| 🔄 **Offline mode** | ✅ Full offline STT | ❌ Requires internet |
| 🔒 **Privacy** | ✅ Zero data leaves your device | ❌ Audio uploaded to servers |
| 💰 **Cost** | ✅ Free forever | ❌ Monthly subscriptions |
| 🔑 **API Keys** | ✅ None required | ❌ Required |
| 🖥️ **Platforms** | ✅ macOS, Windows, Linux + Web | ⚠️ Limited |
| 📦 **Self-hosted API** | ✅ Docker setup included | ❌ Not available |
| 🔌 **Embed widget** | ✅ Add to any website | ❌ Rare |
| ⌨️ **Global shortcut** | ✅ Dictate from anywhere | ⚠️ App-dependent |

---

## Implementations

| Platform | Stack | Location |
|----------|-------|----------|
| **macOS native** | Swift 6 · whisper.cpp · XcodeGen | `VoiceFlow/` |
| **Cross-platform desktop** | Tauri v2 · Rust · whisper-rs | `tauri-app/` |
| **Browser demo** | HTML · Transformers.js · ONNX WASM | `Website/` |

**Tech stack:** Swift 6, Rust, Tauri v2, whisper.cpp, Ollama, Transformers.js, WebAssembly, Docker

---

## Features

- **🔇 Offline dictation** — Speech recognition runs entirely on-device via local Whisper (whisper.cpp / whisper-rs)
- **⌨️ Global shortcut** — `⌘⇧V` (macOS) / `Ctrl+Shift+V` (Windows/Linux) to toggle recording from any app
- **📋 Auto-copy to clipboard** — Optionally paste the transcript into the frontmost application automatically
- **💻 System tray / menu-bar app** — Runs in the background, shows window on demand; Dock-less on macOS (`LSUIElement`)
- **🌊 Streaming transcription** — Optional real-time partial transcripts via Groq's free Whisper API (~275ms latency)
- **✨ Smart editing** — Automatic filler-word removal (um, uh, like), punctuation restoration, and text formatting
- **🎙️ Mini widget** — Floating mic icon for quick one-tap recording from anywhere on screen
- **🌑 Dark premium UI** — Cyan/indigo accent with recording glow animations
- **🔗 Embedded dictation** — Add a floating dictation widget to any website with a single `<script>` tag
- **🐳 Docker support** — Self-hosted Whisper API + local LLM (Ollama) for smart editing

---

## Quick Start

### Prerequisites

- [Node.js](https://nodejs.org/) 18+
- [Rust](https://rustup.rs/) (latest stable)

### macOS

```bash
brew install pkg-config cmake
xcode-select --install
```

### Windows

```powershell
winget install Rustlang.Rustup
# Install Visual Studio Build Tools with "Desktop development with C++"
# https://visualstudio.microsoft.com/visual-cpp-build-tools/
```

### Linux (Ubuntu/Debian)

```bash
sudo apt update
sudo apt install -y libwebkit2gtk-4.1-dev libappindicator3-dev librsvg2-dev \
  patchelf libssl-dev libasound2-dev pkg-config cmake
```

### One-Time Setup (all platforms)

```bash
./scripts/setup.sh        # macOS / Linux
.\scripts\setup.ps1       # Windows (PowerShell)
```

Or do it manually:

```bash
cd tauri-app
npm install
mkdir -p src-tauri/models
curl -L -o src-tauri/models/ggml-base.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin
```

### Build & Run

```bash
cd tauri-app

# Development
npm run tauri dev

# Production — outputs .app/.dmg (macOS), .msi/.exe (Windows), .deb/.AppImage (Linux)
npm run tauri build
```

### Swift macOS App (native)

```bash
# Generate Xcode project from VoiceFlow.yml
brew install xcodegen
xcodegen generate

# Open and build in Xcode
open VoiceFlow.xcodeproj
```

The Swift app uses [whisper.cpp](https://github.com/ggerganov/whisper.cpp) v1.7.4 via SPM and requires `brew install whisper-cpp`.

---

## Streaming Mode (Groq API — Free, Optional)

VoiceFlow includes optional streaming transcription via [Groq's free Whisper API](https://groq.com) for near-instant results (~275ms latency):

1. Get a free API key at [console.groq.com](https://console.groq.com) (no credit card required)
2. Copy `.env.example` to `.env` and add your key:
   ```
   GROQ_API_KEY=gsk_your_key_here
   ```
3. Running `npm run tauri dev` auto-loads `GROQ_API_KEY` from the root `.env`
4. Set it via **Settings → Groq API key** in the app — persists across restarts

> **Note:** Streaming mode is completely optional. VoiceFlow works perfectly offline without it.

---

## Browser Demo (No Installation Required)

Try VoiceFlow directly in your browser — **no download, no install, no account**:

```bash
cd Website
./setup-offline-stt.sh      # one-time: downloads ~40MB of runtime + model
python3 -m http.server 8080 # serve the page
# open http://localhost:8080
```

Microphone access requires HTTP(S); it won't work on `file://`.

The Website demo runs Whisper tiny.en entirely in-browser via **WebAssembly** — zero server calls, full client-side processing.

---

## Embed Dictation on Your Own Website

Add a floating voice dictation widget to any website with two script tags:

```html
<script>
  window.VOICEFLOW_CONFIG = { position: "bottom-right", title: "Dictate", theme: "auto" };
</script>
<script src="/embed/voiceflow-embed.js" defer></script>
```

A floating mic button appears. Visitors can click to record, and their voice is transcribed on-device. Shows a friendly setup message if the model assets aren't hosted alongside it. See **[Website/OFFLINE-STT.md](Website/OFFLINE-STT.md)** for full architecture and privacy details.

**Use cases:** Contact forms, blog comments, accessibility tools, customer support chat.

---

## Architecture

```
Audio Input (16kHz PCM)
    ↓
[Whisper STT]  ← Local (whisper-rs / whisper.cpp) or Groq API
    ↓
Raw Transcript
    ↓
[Smart Editor]  ← Filler removal, auto-edits, punctuation (via Ollama locally)
    ↓
Clean, formatted text → Clipboard / Display / Embed widget
```

---

## Docker — Full Backend Stack & Dev Environment

VoiceFlow ships with a complete Docker setup for **local LLM inference**, a **self-hosted Whisper transcription API** (free alternative to Groq), and a **reproducible Tauri build environment**. No native Rust or WebKit installs required on the host.

### What's included

| Service | Image | Purpose |
|---------|-------|---------|
| `ollama` | `voiceflow/ollama` | Local LLM server (phi-3.5-mini) for smart editing, punctuation, filler removal |
| `whisper-api` | `voiceflow/whisper-api` | Self-hosted Whisper transcription endpoint (`POST /transcribe`) |
| `dev` | `voiceflow/dev` | Tauri build environment — Rust + Node + WebKit deps, all pre-installed |

### Quick start

```bash
# Start Ollama + Whisper API in the background
./scripts/docker-up.sh

# Check status
./scripts/docker-up.sh --status

# Open an interactive dev shell (build the Tauri app inside)
./scripts/docker-up.sh --shell

# Build the desktop app from inside the container
./scripts/build-tauri.sh
```

### Services

- **Ollama** → `http://localhost:11434` — runs `phi-3.5-mini:q4_K_M` by default (~4 GB RAM). Swap the model in `docker-compose.yml` build args for `llama3.2:1b` (1 GB) or `mistral:7b` (5 GB). GPU acceleration available via NVIDIA Container Toolkit.

- **Whisper API** → `http://localhost:8081` — drop-in replacement for Groq. Accepts audio files and returns transcribed text with timestamps. Model size controlled by `WHISPER_MODEL` env var (`tiny` \| `base` \| `small` \| `medium` \| `large-v3`).

- **Dev container** → No exposed ports. Use `docker compose exec dev bash` for an interactive shell, or `docker compose run --rm dev npm run tauri dev` to run the app.

### Architecture in Docker

```
┌─────────────────┐      ┌──────────────────┐      ┌─────────────────┐
│  Tauri App      │─────▶│  ollama:11434     │      │  whisper-api    │
│  (native or     │      │  phi-3.5-mini    │      │  :8081          │
│   in dev ctr)   │      │  (editing layer) │      │  (STT fallback) │
└─────────────────┘      └──────────────────┘      └─────────────────┘
       │                         ▲                          ▲
       │ audio                   │ raw transcript           │ audio file
       ▼                         │ (punctuated, edited)     │
┌─────────────────┐      ┌──────────────────┐      ┌─────────────────┐
│  Microphone     │      │  Named volumes   │      │  Named volume   │
│  (16 kHz PCM)   │      │  (models persist)│      │  (model cache)  │
└─────────────────┘      └──────────────────┘      └─────────────────┘
```

All models are persisted in named Docker volumes — rebuilding containers never re-downloads weights.

### GPU support (optional)

On machines with NVIDIA GPUs, uncomment the `deploy` block in `docker-compose.yml` under the `ollama` service and ensure the [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html) is installed. The Whisper API service also supports `WHISPER_DEVICE=cuda`.

### Docker Compose commands

```bash
# Start backend services only (Ollama + Whisper API)
docker compose up -d

# Full stack including dev shell
docker compose up -d ollama whisper-api dev

# Stop everything (keeps data volumes)
docker compose down

# Rebuild all images from scratch
docker compose build --pull

# View logs
docker compose logs -f ollama
docker compose logs -f whisper-api
```

---

## Privacy & Security

VoiceFlow is built with a **privacy-first philosophy**:

- **Offline mode** makes zero network requests — your audio never leaves your machine
- **Streaming mode** sends audio only to Groq's API (no storage, no logging)
- **Browser demo** enforces a strict CSP and sets `allowRemoteModels = false` to prevent any remote model fetching
- **Docker Whisper API** gives you full control — self-host on your own infrastructure
- **No analytics, no telemetry, no crash reporting** — ever

Your voice data is yours. Always has been. Always will be.

---

## Project Structure

```
VoiceFlow/
├── VoiceFlow/                 # macOS native app (Swift 6 · whisper.cpp)
│   ├── Sources/App/           # SwiftUI views (VoiceFlowApp, VoiceAgentView, etc.)
│   ├── Sources/Audio/         # AudioCaptureEngine (AVAudioRecorder)
│   ├── Sources/Core/          # AppState, AppSettings, DictationCoordinator, PermissionManager
│   ├── Sources/Speech/        # WhisperEngine, TextPostProcessor, ModelManager
│   └── Resources/             # Assets, xcassets
├── Website/                   # Browser demo (Transformers.js · ONNX WebAssembly)
│   ├── index.html + css/style.css
│   ├── js/voice-agent.js      # Offline dictation engine
│   ├── js/vendor/             # Transformers.js + ONNX WASM (populated by setup)
│   ├── models/whisper-tiny.en/  # Local Whisper model (populated by setup)
│   ├── embed/voiceflow-embed.js # Floating dictation widget
│   ├── setup-offline-stt.sh   # One-time setup script
│   └── OFFLINE-STT.md         # Architecture & privacy details
├── tauri-app/                 # Cross-platform desktop app (Tauri v2 · Rust)
│   ├── src/main.ts            # Frontend: recording, streaming, tray UI
│   └── src-tauri/src/         # Backend: audio.rs, whisper.rs, whisperflow.rs, editor.rs
│       ├── models/ggml-base.bin  # Whisper base model (~141MB)
│       └── tauri.conf.json    # App manifest
├── scripts/                     # Setup, Docker, and build helpers
│   ├── setup.sh & setup.ps1     # Cross-platform one-time setup
│   ├── docker-up.sh             # Docker quick-launch manager
│   └── build-tauri.sh           # Build Tauri app inside Docker container
├── docker/                      # Production Docker stack
│   ├── ollama/Dockerfile        # Local LLM server (phi-3.5-mini) for smart editing
│   ├── whisper-api/             # Self-hosted Whisper transcription API
│   │   ├── Dockerfile
│   │   └── app.py               # FastAPI + openai-whisper endpoint
│   └── dev/Dockerfile           # Tauri build env (Rust + Node + WebKit pre-installed)
├── docker-compose.yml           # Orchestrates ollama + whisper-api + dev
├── .dockerignore                # Excludes build artifacts from images
└── VoiceFlow.yml                # XcodeGen config
```

---

## Frequently Asked Questions (FAQ)

### Is VoiceFlow really free and open source?
Yes. VoiceFlow is triple-licensed under MIT, Apache 2.0, and GPL v3. You can use, modify, and distribute it freely. No subscriptions, no hidden fees, no API costs for offline mode.

### Does VoiceFlow work without an internet connection?
Absolutely. The core speech-to-text engine runs Whisper entirely on your device using local models (whisper.cpp / whisper-rs). No network connection needed — not even for model downloads after the initial setup.

### What languages does VoiceFlow support?
VoiceFlow uses OpenAI's Whisper model, which supports **100+ languages** including English, Spanish, French, German, Japanese, Korean, Chinese, Arabic, Hindi, and many more. The browser demo defaults to English (`whisper-tiny.en`); the desktop app supports multilingual models.

### How accurate is offline Whisper compared to cloud STT?
Whisper base model achieves ~95% word accuracy on clean English audio. The `small` and `medium` models are even more accurate. While cloud services like Google dictation may edge it out on accented speech, VoiceFlow's accuracy is competitive for most use cases — and you trade a small accuracy gain for total privacy.

### Can I use VoiceFlow commercially?
Yes. The MIT and Apache 2.0 license options allow commercial use with no restrictions (MIT) or with patent protection (Apache 2.0). Only GPL v3 requires derivative works to also be open source.

### How is VoiceFlow different from Whisper.cpp or other Whisper projects?
Unlike raw Whisper.cpp (which is a library), VoiceFlow is a **complete polished application** with a beautiful UI, global shortcuts, system tray integration, smart text editing (filler removal, punctuation), streaming mode, and an embeddable web widget — all wrapped in a cross-platform desktop app.

### Can I self-host the Whisper API?
Yes! VoiceFlow includes a complete Docker setup with a self-hosted Whisper API (`whisper-api` service on port 8081). You can replace Groq with your own server, giving you full control over your transcription pipeline.

### What are the system requirements?
- **RAM:** 4GB minimum (8GB recommended for larger Whisper models)
- **CPU:** Any modern CPU (ARM64/M-series Macs get native acceleration)
- **GPU:** Optional — NVIDIA CUDA supported in Docker mode
- **Storage:** ~141MB for base model, ~464MB for medium, ~1.5GB for large

---

## License

This project is triple-licensed under your choice of:

| License | Key Points |
|---------|------------|
| [**MIT**](https://opensource.org/licenses/MIT) | Simple, permissive — use anywhere, no restrictions |
| [**Apache 2.0**](https://www.apache.org/licenses/LICENSE-2.0) | MIT + patent protection — contributors grant patent rights |
| [**GPL v3**](https://www.gnu.org/licenses/gpl-3.0.html) | Copyleft — derivative works must also be open source |

You may choose to use, distribute, and/or modify this software under any one (or more) of these licenses. See [LICENSE](LICENSE) for full text.

---

## Star This Repo ⭐

If VoiceFlow saves you time or respects your privacy, give it a star — it helps others discover it!

[![GitHub stars](https://img.shields.io/github/stars/kennethaman0891/VoiceFlow?style=social)](https://github.com/kennethaman0891/VoiceFlow/stargazers)

---

<p align="center">
  <strong>Built with ❤️ by <a href="https://github.com/kennethaman0891">Kenneth Aman</a> · Privacy-first · Open source · No clouds harmed</strong>
</p>
