#!/usr/bin/env bash
# ============================================================
# VoiceFlow — Docker Quick Launch
#
# One-command start of the full VoiceFlow backend stack:
#   Ollama          (local LLM for smart editing)
#   Whisper API     (self-hosted STT fallback)
#
# Usage:
#   ./scripts/docker-up.sh              # start everything
#   ./scripts/docker-up.sh --stop       # stop all services
#   ./scripts/docker-up.sh --shell      # open dev shell
#   ./scripts/docker-up.sh --status     # show running containers
#   ./scripts/docker-up.sh --logs       # follow logs
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE_FILE="$PROJECT_ROOT/docker-compose.yml"

cd "$PROJECT_ROOT"

# ── Helpers ───────────────────────────────────────────────────

cmd() {
  docker compose -f "$COMPOSE_FILE" "$@"
}

usage() {
  cat <<'EOF'
VoiceFlow Docker Manager

  ./scripts/docker-up.sh [option]

Options:
  (none)        Start ollama + whisper-api in background
  --start       Same as above (explicit)
  --stop        Stop and remove containers (keeps volumes)
  --restart     Stop then start
  --shell       Open interactive bash in the dev container
  --status      Show container health & ports
  --logs        Follow logs for all services
  --logs <svc>  Follow logs for one service (ollama | whisper-api | dev)
  --build       Rebuild all images (full rebuild)
  --clean       Remove containers + images (keeps named volumes)
  --help        Show this message
EOF
}

# ── Ensure .env exists ────────────────────────────────────────
if [ ! -f "$PROJECT_ROOT/.env" ] && [ -f "$PROJECT_ROOT/.env.example" ]; then
  echo "[voiceflow] Creating .env from .env.example ..."
  cp "$PROJECT_ROOT/.env.example" "$PROJECT_ROOT/.env"
fi

# ── Commands ──────────────────────────────────────────────────

case "${1:-start}" in
  ""|start|--start)
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  VoiceFlow — Starting backend services"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    cmd up -d ollama whisper-api
    echo ""
    echo "  ✓ Ollama      → http://localhost:11434"
    echo "  ✓ Whisper API → http://localhost:8081"
    echo ""
    echo "  Status: docker compose ps"
    echo "  Logs:   ./scripts/docker-up.sh --logs"
    ;;

  --stop)
    echo "Stopping VoiceFlow services..."
    cmd down
    echo "Done."
    ;;

  --restart)
    cmd down
    cmd up -d
    ;;

  --shell)
    echo "Opening dev shell ..."
    cmd exec dev bash
    ;;

  --status)
    cmd ps
    echo ""
    echo "─ Ollama health ─"
    curl -sf http://localhost:11434/api/tags 2>/dev/null \
      && echo "" \
      || echo "  (not ready yet — check with --logs ollama)"
    echo ""
    echo "─ Whisper API health ─"
    curl -sf http://localhost:8081/health 2>/dev/null \
      && echo "" \
      || echo "  (not ready yet — check with --logs whisper-api)"
    ;;

  --logs)
    svc="${2:-}"
    if [ -n "$svc" ]; then
      cmd logs -f "$svc"
    else
      cmd logs -f
    fi
    ;;

  --build)
    echo "Rebuilding all images ..."
    cmd build --pull
    cmd up -d
    ;;

  --clean)
    echo "Removing containers and images (volumes preserved) ..."
    cmd down --rmi all
    ;;

  --help|-h|help)
    usage
    ;;

  *)
    echo "Unknown option: $1"
    usage
    exit 1
    ;;
esac
