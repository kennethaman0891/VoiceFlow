# ============================================================
# VoiceFlow — Whisper API: lightweight STT fallback server
#
# Provides a local /transcribe endpoint powered by
# openai/whisper (Python) as a self-hosted alternative to Groq.
#
#   curl -X POST http://localhost:8081/transcribe \
#        -F "file=@audio.wav" \
#        -F "model=base"
#
#   Models available: tiny | base | small | medium | large-v3
#
# Build:
#   docker build -f docker/whisper-api/Dockerfile -t voiceflow/whisper-api .
#
# Run:
#   docker run -d -p 8081:8080 \
#     -v voiceflow-whisper-cache:/app/models \
#     --name voiceflow-whisper-api \
#     voiceflow/whisper-api
# ============================================================

FROM python:3.11-slim

# System deps for audio processing
RUN apt-get update && apt-get install -y --no-install-recommends \
    ffmpeg \
    libsndfile1 \
    gcc \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# FastAPI + uvicorn for the HTTP layer; openai-whisper for STT
RUN pip install --no-cache-dir \
    fastapi==0.115.6 \
    uvicorn[standard]==0.32.1 \
    openai-whisper==20240930 \
    soundfile==0.12.1 \
    aiofiles==24.1.0

# Copy application
COPY docker/whisper-api/app.py /app/app.py

# Pre-download the 'base' model on build so first request is instant
RUN python -c "import whisper; whisper.load_model('base')" \
    || echo "Note: model download skipped (no GPU/network in build)"

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=10s --retries=3 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8080/health')" \
  || exit 1

CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8080"]
