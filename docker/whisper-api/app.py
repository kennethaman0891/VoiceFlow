"""
VoiceFlow Whisper API — self-hosted transcription server.
Drop-in replacement for Groq's Whisper endpoint.

Usage:
    curl -X POST http://localhost:8081/transcribe          -F "file=@meeting.mp3"          -F "model=base"          -F "language=en"

Response:
    { "text": "...", "segments": [...], "language": "en" }
"""

from __future__ import annotations

import os
import tempfile
import uuid
from pathlib import Path
from typing import Optional

from fastapi import FastAPI, HTTPException, UploadFile, Form, Request, Depends
from fastapi.responses import JSONResponse
from fastapi.middleware.cors import CORSMiddleware
from slowapi import Limiter, _rate_limit_exceeded_handler
from slowapi.util import get_remote_address
from slowapi.errors import RateLimitExceeded
import uvicorn
import whisper

# ── Configuration ───────────────────────────────────────────────
MODEL_NAME: str = os.getenv("WHISPER_MODEL", "base")          # tiny|base|small|medium|large-v3
MODEL_DEVICE: str = os.getenv("WHISPER_DEVICE", "cpu")       # cpu|cuda
OUTPUT_DIR: Path = Path(os.getenv("WHISPER_CACHE", "/app/models"))
OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

# Security limits
MAX_FILE_SIZE: int = 50 * 1024 * 1024  # 50 MB
ALLOWED_MIME_TYPES: set[str] = {
    "audio/wav", "audio/x-wav", "audio/wave",
    "audio/mp3", "audio/mpeg",
    "audio/mp4", "audio/x-m4a",
    "audio/flac", "audio/x-flac",
    "audio/ogg", "audio/opus",
    "audio/webm",
    "audio/aac", "audio/x-aac",
    "audio/aiff", "audio/x-aiff",
}
ALLOWED_EXTENSIONS: set[str] = {
    ".wav", ".mp3", ".m4a", ".flac", ".ogg", ".opus",
    ".webm", ".aac", ".aiff", ".aif"
}
RATE_LIMIT_DEFAULT: str = "30/minute"
RATE_LIMIT_TRANSCRIBE: str = "10/minute"

app = FastAPI(
    title="VoiceFlow Whisper API",
    description="Self-hosted OpenAI Whisper endpoint — zero telemetry, runs fully offline.",
    version="1.0.0",
)

# CORS - restrict to localhost for security
app.add_middleware(
    CORSMiddleware,
    allow_origins=["http://localhost:5173", "http://localhost:3000", "http://127.0.0.1:5173", "http://127.0.0.1:3000", "tauri://localhost"],
    allow_credentials=False,
    allow_methods=["GET", "POST"],
    allow_headers=["*"],
)

# Rate limiter
limiter = Limiter(key_func=get_remote_address, default_limits=[RATE_LIMIT_DEFAULT])
app.state.limiter = limiter
app.add_exception_handler(RateLimitExceeded, _rate_limit_exceeded_handler)

# ── Model loading (lazy — on first request) ─────────────────────
_model: Optional[whisper.Whisper] = None

def get_model() -> whisper.Whisper:
    global _model
    if _model is None:
        print(f"[whisper-api] Loading model '{MODEL_NAME}' on {MODEL_DEVICE} ...")
        _model = whisper.load_model(MODEL_NAME)
        print("[whisper-api] Model ready.")
    return _model

# ── Validation helpers ──────────────────────────────────────────

def validate_file(file: UploadFile) -> None:
    """Validate uploaded file size, MIME type, and extension."""
    # Check filename
    if not file.filename:
        raise HTTPException(status_code=400, detail="No filename provided")

    # Check extension
    ext = Path(file.filename).suffix.lower()
    if ext not in ALLOWED_EXTENSIONS:
        raise HTTPException(
            status_code=400,
            detail=f"File extension '{ext}' not allowed. Allowed: {', '.join(sorted(ALLOWED_EXTENSIONS))}"
        )

    # Check MIME type (from content-type header)
    content_type = file.content_type or ""
    if content_type and content_type not in ALLOWED_MIME_TYPES:
        raise HTTPException(
            status_code=400,
            detail=f"MIME type '{content_type}' not allowed. Allowed: {', '.join(sorted(ALLOWED_MIME_TYPES))}"
        )

def sanitize_filename(filename: str) -> str:
    """Sanitize filename to prevent path traversal."""
    # Keep only the basename
    name = Path(filename).name
    # Remove any non-alphanumeric chars except . _ -
    import re
    name = re.sub(r'[^a-zA-Z0-9._-]', '_', name)
    # Limit length
    if len(name) > 255:
        name = name[:255]
    return name

# ── Endpoints ───────────────────────────────────────────────────

@app.get("/health")
async def health() -> dict[str, str]:
    status = "loaded" if _model is not None else "loading"
    return {"status": status, "model": MODEL_NAME, "device": MODEL_DEVICE}

@app.post("/transcribe")
@limiter.limit(RATE_LIMIT_TRANSCRIBE)
async def transcribe(
    request: Request,
    file: UploadFile,
    model: str = Form("base"),
    language: Optional[str] = Form(None),
    task: str = Form("transcribe"),
    temperature: float = Form(0.0),
):
    """Transcribe an audio file. Returns text + optional segments."""
    # Validate file
    validate_file(file)

    # Validate model name
    valid_models = {"tiny", "base", "small", "medium", "large-v3", "large-v2", "large-v1"}
    if model not in valid_models:
        raise HTTPException(status_code=400, detail=f"Invalid model. Choose from: {', '.join(sorted(valid_models))}")

    # Validate task
    if task not in ("transcribe", "translate"):
        raise HTTPException(status_code=400, detail="Task must be 'transcribe' or 'translate'")

    # Validate temperature
    if not 0.0 <= temperature <= 1.0:
        raise HTTPException(status_code=400, detail="Temperature must be between 0.0 and 1.0")

    # Validate language if provided
    if language is not None:
        if not isinstance(language, str) or len(language) > 10:
            raise HTTPException(status_code=400, detail="Invalid language code")

    # Read file with size limit
    content = await file.read()
    if len(content) > MAX_FILE_SIZE:
        raise HTTPException(status_code=413, detail=f"File too large. Maximum size: {MAX_FILE_SIZE // (1024*1024)} MB")
    if len(content) == 0:
        raise HTTPException(status_code=400, detail="Empty file")

    # Sanitize filename for temp file
    safe_suffix = Path(sanitize_filename(file.filename)).suffix
    if safe_suffix not in ALLOWED_EXTENSIONS:
        safe_suffix = ".wav"

    tmp = tempfile.NamedTemporaryFile(suffix=safe_suffix, delete=False)
    try:
        tmp.write(content)
        tmp.close()

        whisp = get_model()
        # Reload model if different one requested
        if whisp.model_name != model:
            global _model
            _model = whisper.load_model(model)

        result = whisp.transcribe(
            tmp.name,
            language=language,
            task=task,
            temperature=temperature,
            word_timestamps=(task == "translate"),
        )

        text = result["text"].strip()
        segments = [
            {
                "start": round(s["start"], 2),
                "end": round(s["end"], 2),
                "text": s["text"].strip(),
            }
            for s in result.get("segments", [])
        ]

        return {
            "text": text,
            "language": result.get("language", language or "auto"),
            "segments": segments,
            "duration_seconds": round(result.get("duration", 0), 2),
        }
    finally:
        try:
            os.unlink(tmp.name)
        except OSError:
            pass

@app.post("/transcribe-streaming")
@limiter.limit(RATE_LIMIT_TRANSCRIBE)
async def transcribe_streaming(
    request: Request,
    file: UploadFile,
    model: str = Form("base"),
    language: Optional[str] = Form(None),
    chunk_length: float = Form(30.0),
):
    """Streaming-style transcription — returns segments as they become available."""
    # Validate file
    validate_file(file)

    # Validate model name
    valid_models = {"tiny", "base", "small", "medium", "large-v3", "large-v2", "large-v1"}
    if model not in valid_models:
        raise HTTPException(status_code=400, detail=f"Invalid model. Choose from: {', '.join(sorted(valid_models))}")

    # Read file with size limit
    content = await file.read()
    if len(content) > MAX_FILE_SIZE:
        raise HTTPException(status_code=413, detail=f"File too large. Maximum size: {MAX_FILE_SIZE // (1024*1024)} MB")
    if len(content) == 0:
        raise HTTPException(status_code=400, detail="Empty file")

    # Sanitize filename for temp file
    safe_suffix = Path(sanitize_filename(file.filename)).suffix
    if safe_suffix not in ALLOWED_EXTENSIONS:
        safe_suffix = ".wav"

    tmp = tempfile.NamedTemporaryFile(suffix=safe_suffix, delete=False)
    try:
        tmp.write(content)
        tmp.close()

        whisp = get_model()
        if whisp.model_name != model:
            global _model
            _model = whisper.load_model(model)

        result = whisp.transcribe(
            tmp.name,
            language=language,
            chunk_length_s=chunk_length,
            batch_size=16,
            conditionally_preprocess=False,
        )

        segments = [
            {
                "start": round(s["start"], 2),
                "end": round(s["end"], 2),
                "text": s["text"].strip(),
            }
            for s in result.get("segments", [])
        ]
        return {"text": result["text"].strip(), "segments": segments}
    finally:
        try:
            os.unlink(tmp.name)
        except OSError:
            pass

if __name__ == "__main__":
    uvicorn.run("app:app", host="0.0.0.0", port=8080, log_level="info")
