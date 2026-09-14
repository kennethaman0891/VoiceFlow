#!/usr/bin/env bash
# ============================================================
# VoiceFlow — Build Tauri app inside the Docker dev container
#
# Downloads the Whisper model, installs deps, and runs the
# Tauri build pipeline. Output lands in tauri-app/dist/.
#
# Usage:
#   ./scripts/build-tauri.sh                  # Linux x64 (default)
#   ./scripts/build-tauri.sh --macos          # macOS binary
#   ./scripts/build-tauri.sh --windows        # Windows MSI/NSIS
#   ./scripts/build-tauri.sh --dev            # dev mode (faster, unsigned)
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE_FILE="$PROJECT_ROOT/docker-compose.yml"

cd "$PROJECT_ROOT"

MODE="${1:-}"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  VoiceFlow — Tauri Build (Docker)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── Download Whisper model inside the container (persistent volume) ─
echo "[1/4] Ensuring Whisper model is downloaded ..."
docker compose -f "$COMPOSE_FILE" run --rm dev \
  bash -c '
    mkdir -p src-tauri/models
    if [ ! -f src-tauri/models/ggml-base.bin ]; then
      curl -L -o src-tauri/models/ggml-base.bin \
        https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin
      echo "  ✓ Model downloaded (ggml-base.bin)"
    else
      echo "  ✓ Model already present"
    fi
  '

# ── Install Node dependencies ──────────────────────────────────
echo "[2/4] Installing npm dependencies ..."
docker compose -f "$COMPOSE_FILE" run --rm dev \
  bash -c 'cd /workspace/tauri-app && npm install'

# ── Build ──────────────────────────────────────────────────────
echo "[3/4] Building Tauri app ..."
BUILD_ARGS=()
if [ "$MODE" = "--dev" ]; then
  BUILD_ARGS=(npm run tauri dev)
elif [ "$MODE" = "--macos" ]; then
  BUILD_ARGS=(npm run tauri build)
elif [ "$MODE" = "--windows" ]; then
  BUILD_ARGS=(npm run tauri build)
else
  # Linux AppImage + deb (default)
  BUILD_ARGS=(npm run tauri build)
fi

docker compose -f "$COMPOSE_FILE" run --rm dev "${BUILD_ARGS[@]}"

# ── Report output ──────────────────────────────────────────────
echo "[4/4] Done!"
echo ""
echo "  Outputs (bind-mounted from container):"
if [ -d "$PROJECT_ROOT/tauri-app/dist" ]; then
  find "$PROJECT_ROOT/tauri-app/dist" -type f \( -name "*.AppImage" -o -name "*.deb" -o -name "*.rpm" -o -name "*.msi" -o -name "*.exe" -o -name "*.dmg" \) 2>/dev/null | while read -r f; do
    echo "    📦 $f"
  done
fi
echo ""
echo "  Full log: docker compose -f $COMPOSE_FILE logs dev"
