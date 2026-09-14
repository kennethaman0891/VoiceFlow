#!/usr/bin/env bash
#
# setup-offline-stt.sh — one-time setup for VoiceFlow's on-device dictation demo.
#
# Run this ONCE on a machine with internet. It downloads, into local folders next
# to this script, everything the website needs to transcribe speech fully offline:
#
#   1. Transformers.js (the ES-module runtime) + its ONNX WebAssembly binaries
#      ->  js/vendor/
#   2. The quantized Whisper "tiny.en" speech-to-text model
#      ->  models/whisper-tiny.en/
#
# After it finishes, the site loads the library and model from these same-origin
# paths only. No CDN, no API, no telemetry — your audio never leaves the device.
#
# Everything is fetched from the official jsDelivr (npm) and Hugging Face mirrors.
# Total download is roughly 40 MB. Safe to re-run; it overwrites in place.
#
# Usage:
#   cd Website
#   ./setup-offline-stt.sh
#
set -uo pipefail

# --- Pin versions here (bump when you want to upgrade) -----------------------
TRANSFORMERS_VERSION="2.17.2"
# @xenova/transformers @ 2.17.2 bundles onnxruntime-web 1.14.0; its ONNX wasm
# binaries live alongside the library in the same dist/ folder, which is exactly
# what env.backends.onnx.wasm.wasmPaths ('./js/vendor/') will point at.
CDN="https://cdn.jsdelivr.net/npm/@xenova/transformers@${TRANSFORMERS_VERSION}/dist"

# Xenova/whisper-tiny.en — English-only, quantized ONNX build for Transformers.js
HF="https://huggingface.co/Xenova/whisper-tiny.en/resolve/main"

# --- Resolve paths relative to this script (so it works from anywhere) -------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENDOR_DIR="${SCRIPT_DIR}/js/vendor"
MODEL_DIR="${SCRIPT_DIR}/models/whisper-tiny.en"

# --- Pretty output -----------------------------------------------------------
bold=$'\033[1m'; green=$'\033[32m'; yellow=$'\033[33m'; red=$'\033[31m'; dim=$'\033[2m'; reset=$'\033[0m'
info()  { echo "${bold}▸${reset} $*"; }
ok()    { echo "  ${green}✓${reset} $*"; }
warn()  { echo "  ${yellow}!${reset} $*"; }
fail()  { echo "  ${red}✗${reset} $*"; }

FAILED_REQUIRED=0

# fetch <url> <dest> <required|optional>
fetch() {
  local url="$1" dest="$2" mode="${3:-required}"
  mkdir -p "$(dirname "$dest")"
  # -f: fail on HTTP errors, -S: show errors, -L: follow redirects (HF uses them)
  if curl -fSL --retry 3 --retry-delay 2 -o "$dest" "$url"; then
    ok "$(basename "$dest")  ${dim}($(du -h "$dest" 2>/dev/null | cut -f1))${reset}"
  else
    if [ "$mode" = "optional" ]; then
      warn "skipped (not found): $(basename "$dest")  ${dim}— optional${reset}"
      rm -f "$dest"
    else
      fail "could not download required file: $url"
      FAILED_REQUIRED=1
    fi
  fi
}

command -v curl >/dev/null 2>&1 || { fail "curl is required but not installed."; exit 1; }

echo
echo "${bold}VoiceFlow — offline dictation setup${reset}"
echo "${dim}Downloading the on-device speech model and runtime (~40 MB, one time).${reset}"
echo

# --- 1. Transformers.js runtime + ONNX WebAssembly binaries -------------------
info "Transformers.js runtime + WASM  ->  js/vendor/"
mkdir -p "$VENDOR_DIR"
fetch "${CDN}/transformers.min.js"              "${VENDOR_DIR}/transformers.min.js"              required
# ONNX Runtime Web wasm binaries (loaded by the library at inference time).
# Different browsers pick different variants (SIMD / threads), so grab them all;
# any that a given library version doesn't ship are treated as optional.
fetch "${CDN}/ort-wasm.wasm"                    "${VENDOR_DIR}/ort-wasm.wasm"                    optional
fetch "${CDN}/ort-wasm-simd.wasm"               "${VENDOR_DIR}/ort-wasm-simd.wasm"               required
fetch "${CDN}/ort-wasm-threaded.wasm"           "${VENDOR_DIR}/ort-wasm-threaded.wasm"           optional
fetch "${CDN}/ort-wasm-simd-threaded.wasm"      "${VENDOR_DIR}/ort-wasm-simd-threaded.wasm"      optional
echo

# --- 2. Whisper tiny.en model files ------------------------------------------
info "Whisper tiny.en model  ->  models/whisper-tiny.en/"
mkdir -p "${MODEL_DIR}/onnx"
# Config + tokenizer + feature extractor (small JSON files, all required)
fetch "${HF}/config.json"                       "${MODEL_DIR}/config.json"                       required
fetch "${HF}/tokenizer.json"                    "${MODEL_DIR}/tokenizer.json"                    required
fetch "${HF}/tokenizer_config.json"             "${MODEL_DIR}/tokenizer_config.json"             required
fetch "${HF}/preprocessor_config.json"          "${MODEL_DIR}/preprocessor_config.json"          required
fetch "${HF}/generation_config.json"            "${MODEL_DIR}/generation_config.json"            optional
fetch "${HF}/vocab.json"                        "${MODEL_DIR}/vocab.json"                        optional
fetch "${HF}/merges.txt"                        "${MODEL_DIR}/merges.txt"                        optional
fetch "${HF}/normalizer.json"                   "${MODEL_DIR}/normalizer.json"                   optional
fetch "${HF}/special_tokens_map.json"           "${MODEL_DIR}/special_tokens_map.json"           optional
fetch "${HF}/added_tokens.json"                 "${MODEL_DIR}/added_tokens.json"                 optional
# Quantized ONNX weights — this is what the site loads (quantized: true)
fetch "${HF}/onnx/encoder_model_quantized.onnx"        "${MODEL_DIR}/onnx/encoder_model_quantized.onnx"        required
fetch "${HF}/onnx/decoder_model_merged_quantized.onnx" "${MODEL_DIR}/onnx/decoder_model_merged_quantized.onnx" required
echo

# --- Done --------------------------------------------------------------------
if [ "$FAILED_REQUIRED" -ne 0 ]; then
  echo "${red}${bold}Setup incomplete.${reset} One or more required files failed to download."
  echo "Check your internet connection and re-run: ${bold}./setup-offline-stt.sh${reset}"
  exit 1
fi

echo "${green}${bold}Done — offline dictation ready.${reset}"
echo
echo "Next:"
echo "  1. Serve the site (mic access needs http, not file://):"
echo "       ${bold}python3 -m http.server 8080${reset}   ${dim}(run from the Website folder)${reset}"
echo "  2. Open ${bold}http://localhost:8080${reset} and press ${bold}Start dictation${reset}."
echo
echo "${dim}Everything now loads from js/vendor/ and models/ on this origin only —${reset}"
echo "${dim}no network request is made while you dictate. Verify in your browser's${reset}"
echo "${dim}Network tab: you'll see zero requests during transcription.${reset}"
echo
