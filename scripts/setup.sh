#!/usr/bin/env bash
# ============================================================
# VoiceFlow — Setup Script (macOS / Linux)
# Creates .env, installs dependencies, downloads Whisper model
# ============================================================
set -e

echo "=============================================="
echo "  VoiceFlow — One-time Setup"
echo "=============================================="

# 1. Create .env from .env.example if it doesn't exist
if [ ! -f .env ]; then
  echo ""
  echo "[1/3] Creating .env file..."
  cp .env.example .env
  echo "  ✅ Created .env — add your GROQ_API_KEY (or leave blank for offline mode)"
else
  echo ""
  echo "[1/3] .env already exists — skipping"
fi

# 2. Install npm dependencies
echo ""
echo "[2/3] Installing npm dependencies..."
cd tauri-app
npm install
echo "  ✅ npm install complete"

# 3. Download Whisper model if not present
echo ""
echo "[3/3] Checking Whisper model..."
if [ -f src-tauri/models/ggml-base.bin ]; then
  echo "  ✅ Model already downloaded"
else
  echo "  ⏳ Downloading ggml-base.bin (141MB)..."
  mkdir -p src-tauri/models
  curl -L -o src-tauri/models/ggml-base.bin \
    https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin
  echo "  ✅ Model downloaded"
fi

echo ""
echo "=============================================="
echo "  Setup complete!"
echo "  Run:  npm run tauri dev   (development)"
echo "        npm run tauri build (production)"
echo "=============================================="
