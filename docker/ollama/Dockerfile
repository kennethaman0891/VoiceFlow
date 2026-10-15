# ============================================================
# VoiceFlow — Ollama: local LLM for smart-editing layer
#
# Runs Ollama with quantized models suitable for transcript
# editing (punctuation, filler removal, style adaptation).
#
#   Models:
#     phi-3.5-mini      — fast, ~4 GB  (default, good for most machines)
#     llama3.2:1b       — ultra-lightweight, ~1 GB (CPU-only friendly)
#     mistral:7b        — higher quality, ~5 GB
#
# Build:
#   docker build -f docker/ollama/Dockerfile -t voiceflow/ollama .
#
# Run (GPU):
#   docker run -d --gpus all -p 11434:11434 #     -v voiceflow-ollama-data:/root/.ollama #     -e OLLAMA_MODELS=/root/.ollama/models #     --name voiceflow-ollama #     voiceflow/ollama
#
# Run (CPU only):
#   docker run -d -p 11434:11434 #     -v voiceflow-ollama-data:/root/.ollama #     --name voiceflow-ollama #     voiceflow/ollama
# ============================================================

FROM ollama/ollama:latest

# Create non-root user (ollama user may already exist, check and create if needed)
RUN if ! id -u ollama >/dev/null 2>&1; then         groupadd -r ollama && useradd -r -g ollama -d /home/ollama -s /sbin/nologin ollama;     fi &&     mkdir -p /home/ollama/.ollama/models && chown -R ollama:ollama /home/ollama

# Switch to non-root user
USER ollama

# Set home directory
ENV HOME=/home/ollama
ENV OLLAMA_MODELS=/home/ollama/.ollama/models

# ── Models to pre-pull (uncomment the ones you want) ──────────────
# phi-3.5-mini is the sweet spot: small, fast, good for text editing
# llama3.2:1b if you have <8 GB RAM
# mistral:7b   if you want better quality and have a GPU

ARG PULL_MODELS="phi-3.5-mini:q4_K_M"

# Note: Model pulling happens as root in build, but we need to run as ollama user
# Models will be downloaded to OLLAMA_MODELS which is owned by ollama user
RUN echo "Pre-pulling Ollama models: ${PULL_MODELS}" &&     for model in ${PULL_MODELS}; do       echo "==> Pulling $model ...";       ollama pull "$model";     done &&     echo "Done. Models ready."

# Expose Ollama API
EXPOSE 11434

# Health check — Ollama answers /api/tags within seconds of start
HEALTHCHECK --interval=30s --timeout=10s --retries=5   CMD ["/usr/bin/curl", "-f", "http://localhost:11434/api/tags"] || exit 1

# Default command — run Ollama server in foreground
CMD ["serve"]
