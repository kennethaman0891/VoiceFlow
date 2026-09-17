# VoiceFlow

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE) [![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE) [![License: GPL v3](https://img.shields.io/badge/License-GPL_v3-blue)](LICENSE) [![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Windows%20%7C%20Linux-lightgrey.svg)](#) [![GitHub stars](https://img.shields.io/github/stars/kennethaman0891/VoiceFlow?style=social)](https://github.com/kennethaman0891/VoiceFlow/stargazers)

**Privacy-first offline speech-to-text & voice dictation.** Runs Whisper entirely on-device — no cloud, no API keys, no telemetry.

| Platform | Stack |
|----------|-------|
| macOS native | Swift 6 · whisper.cpp |
| Cross-platform desktop | Tauri v2 · Rust |
| Browser demo | Transformers.js · ONNX WASM |

![VoiceFlow UI](voiceflow-ui.png)
![VoiceFlow Mic](voiceflow-mic-final.png)
![VoiceFlow Showcase](voiceflow-mic-showcase.png)

---

## Features

- **Offline dictation** — Whisper runs locally; zero network requests
- **Global shortcut** — `⌘⇧V` / `Ctrl+Shift+V` from any app
- **Auto-copy to clipboard** — Transcript pastes into whatever you're using
- **Streaming mode** — Optional Groq API for ~275ms latency (fully offline works without it)
- **Smart editing** — Filler-word removal, auto-punctuation via local Ollama
- **Embed widget** — One `<script>` tag adds a floating mic to any website
- **Docker stack** — Self-hosted Whisper API + Ollama LLM

---

## Quick Start

### Prerequisites

- [Node.js](https://nodejs.org/) 18+
- [Rust](https://rustup.rs/) (latest stable)

```bash
# macOS
brew install pkg-config cmake && xcode-select --install

# Windows — install Build Tools with "Desktop development with C++"
# https://visualstudio.microsoft.com/visual-cpp-build-tools/

# Linux (Ubuntu/Debian)
sudo apt install -y libwebkit2gtk-4.1-dev libappindicator3-dev librsvg2-dev patchelf
```

### Desktop App

```bash
cd tauri-app
npm install                          # one-time setup
mkdir -p src-tauri/models
curl -L -o src-tauri/models/ggml-base.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin

npm run tauri dev    # development
npm run tauri build  # production (.app/.dmg/.exe/.deb)
```

### Swift macOS App

```bash
brew install xcodegen
xcodegen generate
open VoiceFlow.xcodeproj
```

### Browser Demo

```bash
cd Website
./setup-offline-stt.sh      # downloads ~40 MB of runtime + model
python3 -m http.server 8080
# open http://localhost:8080
```

See [tauri-app/README.md](tauri-app/README.md) and [Website/OFFLINE-STT.md](Website/OFFLINE-STT.md) for full details.

---

## Docker (Self-Hosted API + LLM)

```bash
./scripts/docker-up.sh          # Start Ollama + Whisper API
docker compose up -d            # or manual compose
./scripts/build-tauri.sh        # Build desktop app in container
```

Services: Ollama `:11434` (smart editing), Whisper API `:8081` (transcription). All models persist in named volumes. GPU support available via NVIDIA Container Toolkit.

---

## Embed on Your Site

```html
<script>window.VOICEFLOW_CONFIG = { position: "bottom-right" };</script>
<script src="/embed/voiceflow-embed.js" defer></script>
```

A floating mic button appears. Audio transcribes on-device — never leaves the visitor's browser.

---

## Architecture

```
Microphone → [Whisper STT] → [Smart Editor (Ollama)] → Clipboard / Display
              (local or           (filler removal,
               Groq API)           punctuation)
```

---

## License

Triple-licensed under **MIT** · **Apache 2.0** · **GPL v3** — your choice. Free forever, no subscriptions, no hidden fees.
