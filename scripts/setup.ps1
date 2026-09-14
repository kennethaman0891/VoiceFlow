# ============================================================
# VoiceFlow — Setup Script (Windows PowerShell)
# Creates .env, installs dependencies, downloads Whisper model
# ============================================================
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "  VoiceFlow - One-time Setup (Windows)" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan

# 1. Create .env from .env.example if it doesn't exist
if (-not (Test-Path .env)) {
    Write-Host ""
    Write-Host "[1/3] Creating .env file..." -ForegroundColor Yellow
    Copy-Item .env.example .env
    Write-Host "  OK: Created .env - add your GROQ_API_KEY (or leave blank for offline mode)" -ForegroundColor Green
} else {
    Write-Host ""
    Write-Host "[1/3] .env already exists - skipping" -ForegroundColor Green
}

# 2. Install npm dependencies
Write-Host ""
Write-Host "[2/3] Installing npm dependencies..." -ForegroundColor Yellow
Set-Location tauri-app
npm install
Write-Host "  OK: npm install complete" -ForegroundColor Green

# 3. Download Whisper model if not present
Write-Host ""
Write-Host "[3/3] Checking Whisper model..." -ForegroundColor Yellow
if (Test-Path src-tauri\models\ggml-base.bin) {
    Write-Host "  OK: Model already downloaded" -ForegroundColor Green
} else {
    Write-Host "  Downloading ggml-base.bin (141MB)..." -ForegroundColor Yellow
    New-Item -ItemType Directory -Force -Path src-tauri\models | Out-Null
    Invoke-WebRequest -Uri "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin" -OutFile src-tauri\models\ggml-base.bin
    Write-Host "  OK: Model downloaded" -ForegroundColor Green
}

Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "  Setup complete!" -ForegroundColor Cyan
Write-Host "  Run:  npm run tauri dev    (development)" -ForegroundColor White
Write-Host "        npm run tauri build  (production)" -ForegroundColor White
Write-Host "==============================================" -ForegroundColor Cyan
