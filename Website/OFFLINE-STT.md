# Offline dictation — how the demo works and why it's private

The VoiceFlow website includes a **live dictation demo that runs a Whisper speech
model entirely on your device**. You speak, it types. No audio, and no transcript,
ever leaves the browser — because there is nothing to send it to. There is no
backend, no API key, and no third-party service involved at runtime.

This document explains the one-time setup and exactly why the privacy claim holds.

---

## One-time setup (required for dictation to work)

The speech model and its runtime are not checked into the repo (they're ~40 MB of
vendored binaries). You download them **once per machine**, on a machine with
internet:

```bash
cd Website
./setup-offline-stt.sh
```

That script populates two local folders:

| Folder | Contents |
| --- | --- |
| `js/vendor/` | `transformers.min.js` (the Transformers.js ES-module runtime) and the ONNX Runtime Web `ort-wasm*.wasm` binaries |
| `models/whisper-tiny.en/` | The quantized Whisper **tiny.en** model — `config.json`, tokenizer/preprocessor JSON, and the `onnx/*_quantized.onnx` weights |

Then serve the folder over http(s) — the browser blocks microphone access on
`file://`, so a local server (or any http(s) origin) is required:

```bash
python3 -m http.server 8080     # from the Website folder
# open http://localhost:8080
```

Click **Start dictation**, allow the microphone once, and speak. The first run
loads the model into the browser cache (a progress bar shows this); every run
after that is instant and works with your network fully disconnected. Once the
assets are installed, the page loads with **zero console errors**.

If you skip setup, the site still looks and behaves perfectly — the demo card just
shows: *"Offline dictation model not installed yet — run `./setup-offline-stt.sh`
(one-time, ~40 MB) to enable on-device transcription."*

---

## How the pipeline works

1. **Capture** — `navigator.mediaDevices.getUserMedia` opens the mic. Raw audio is
   collected in the browser via the Web Audio API (no file is written, no upload).
2. **Downsample** — the audio is converted to 16 kHz mono `Float32` in-page, the
   format Whisper expects.
3. **Transcribe** — Transformers.js runs the Whisper tiny.en model in WebAssembly
   (ONNX Runtime Web). The library is configured to be strictly local:

   ```js
   env.allowRemoteModels = false;              // never fetch models from the internet
   env.localModelPath = './models/';           // load weights from this origin only
   env.backends.onnx.wasm.wasmPaths = './js/vendor/';  // WASM binaries are local too
   ```
4. **Show** — the transcript appears in the card with a **Copy** button. The audio
   buffer is discarded when transcription finishes.

The desktop apps (macOS + Windows) use the same idea with Whisper.cpp running
locally — no cloud speech service on either platform.

---

## Why nothing leaves your device

- **`allowRemoteModels = false`** — Transformers.js is hard-configured to refuse
  remote model downloads. Weights come only from `./models/` on this origin.
- **Same-origin assets only** — the runtime, the WASM, and the model are all served
  from the site's own origin (`js/vendor/`, `models/`). No CDN is contacted at
  runtime.
- **No backend** — the code contains no `fetch`/`XMLHttpRequest`/`WebSocket` to any
  remote host, no analytics, and no web fonts. The old Web Speech API path (which
  streamed audio to Google) has been removed entirely.
- **Strict Content-Security-Policy** — `index.html` ships a CSP that only permits
  `'self'` for scripts, connections, media, workers and fonts, so the browser
  itself would block any accidental outbound request.

### Verify it yourself

Open your browser's **Network tab**, then dictate. During recording and
transcription you will see **zero network requests** (the model files load once on
first use and are then served from cache). That's the whole guarantee, and you can
confirm it in ten seconds.
