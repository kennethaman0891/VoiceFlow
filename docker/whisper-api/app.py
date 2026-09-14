"""
VoiceFlow Whisper API — self-hosted transcription server.
Drop-in replacement for Groq's Whisper endpoint.

Usage:
    curl -X POST http://localhost:8081/transcribe \
         -F "file=@meeting.mp3" \
         -F "model=base" \
         -F "language=en"

Response:
    { "text": "...", "segments": [...], "language": "en" }
"""

from __future__ import annotations

import os
import tempfile
import uuid
from pathlib import Path
from typing import Optional

from fastapi import FastAPI, HTTPException, UploadFile, Form
from fastapi.responses import JSONResponse
import uvicorn
import whisper

# ── Configuration ───────────────────────────────────────────────
MODEL_NAME: str = os.getenv("WHISPER_MODEL", "base")          # tiny|base|small|medium|large-v3
MODEL_DEVICE: str = os.getenv("WHISPER_DEVICE", "cpu")       # cpu|cuda
OUTPUT_DIR: Path = Path(os.getenv("WHISPER_CACHE", "/app/models"))
OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

app = FastAPI(
    title="VoiceFlow Whisper API",
    description="Self-hosted OpenAI Whisper endpoint — zero telemetry, runs fully offline.",
    version="1.0.0",
)

# ── Model loading (lazy — on first request) ─────────────────────
_model: Optional[whisper.Whisper] = None


def get_model() -> whisper.Whisper:
    global _model
    if _model is None:
        print(f"[whisper-api] Loading model '{MODEL_NAME}' on {MODEL_DEVICE} ...")
        _model = whisper.load_model(MODEL_NAME)
        print("[whisper-api] Model ready.")
    return _model


# ── Endpoints ───────────────────────────────────────────────────

@app.get("/health")
async def health() -> dict[str, str]:
    status = "loaded" if _model is not None else "loading"
    return {"status": status, "model": MODEL_NAME, "device": MODEL_DEVICE}


@app.post("/transcribe")
async def transcribe(
    file: UploadFile,
    model: str = Form("base"),
    language: Optional[str] = Form(None),
    task: str = Form("transcribe"),
    temperature: float = Form(0.0),
):
    """Transcribe an audio file. Returns text + optional segments."""
    if not file.filename:
        raise HTTPException(400, "No filename provided")

    # Validate model name
    valid_models = {"tiny", "base", "small", "medium", "large-v3", "large-v2", "large-v1"}
    if model not in valid_models:
        raise HTTPException(400, f"Invalid model. Choose from: {', '.join(sorted(valid_models))}")

    # Write upload to temp file
    suffix = Path(file.filename).suffix
    tmp = tempfile.NamedTemporaryFile(suffix=suffix, delete=False)
    try:
        content = await file.read()
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
        os.unlink(tmp.name)


@app.post("/transcribe-streaming")
async def transcribe_streaming(
    file: UploadFile,
    model: str = Form("base"),
    language: Optional[str] = Form(None),
    chunk_length: float = Form(30.0),
):
    """Streaming-style transcription — returns segments as they become available."""
    suffix = Path(file.filename).suffix
    tmp = tempfile.NamedTemporaryFile(suffix=suffix, delete=False)
    try:
        content = await file.read()
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
        os.unlink(tmp.name)


if __name__ == "__main__":
    uvicorn.run("app:app", host="0.0.0.0", port=8080, log_level="info")
