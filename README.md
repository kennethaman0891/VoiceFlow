# VoiceFlow

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE) [![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE) [![License: GPL v3](https://img.shields.io/badge/License-GPL_v3-blue)](LICENSE) [![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Windows%20%7C%20Linux-lightgrey.svg)](#) [![Language](https://img.shields.io/badge/language-Swift%20%7C%20Rust%20%7C%20JavaScript-orange.svg)](#) [![GitHub stars](https://img.shields.io/github/stars/kennethaman0891/VoiceFlow?style=social)](https://github.com/kennethaman0891/VoiceFlow/stargazers) [![GitHub forks](https://img.shields.io/github/forks/kennethaman0891/VoiceFlow?style=social)](https://github.com/kennethaman0891/VoiceFlow/network/members)

<div align="center">

**Privacy-first offline speech-to-text & voice dictation for macOS, Windows & Linux.** Runs Whisper entirely on-device — no cloud, no API keys, no telemetry.

[**Download**](#quick-start) · [**Browser Demo**](#browser-demo) · [**Docker Setup**](#docker--full-backend-stack--dev-environment) · [**GitHub**](https://github.com/kennethaman0891/VoiceFlow)

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

## Docker — Full Backend Stack & Dev Environment

VoiceFlow ships with a complete Docker setup for **local LLM inference**, a **self-hosted Whisper transcription API** (free alternative to Groq), and a **reproducible Tauri build environment**. No native Rust or WebKit installs required on the host.

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
