# VoiceFlow Website — on-device dictation

A pure **offline dictation** site: speak, and a local Whisper model turns it into
text right in the browser. No audio, transcript, or telemetry ever leaves the
device — there is no backend, no API, and no third-party service at runtime.

- **Web:** `index.html` + inline demo (`js/voice-agent.js`) + floating embed widget (`embed/voiceflow-embed.js`)
- **Desktop:** native macOS + Windows apps that dictate on-device with Whisper.cpp

## Quick start

### One-time setup

The speech model and runtime aren't committed (they're ~40 MB of vendored
binaries). Fetch them **once** on a machine with internet:

```bash
cd Website
./setup-offline-stt.sh        # downloads Transformers.js + Whisper tiny.en locally
```

Run it just once per machine. After it finishes you'll have the runtime in
`js/vendor/` and the Whisper model in `models/`.

### Serve & run

Microphone access requires the site to be served over http(s) — it is blocked on
`file://`.

```bash
python3 -m http.server 8080   # from the Website folder
# open http://localhost:8080
```

Press **Start dictation**, allow the mic once, and speak. The first run loads the
model into the browser cache; after that it works fully offline. With the assets
installed, the page loads with **zero console errors**.

If you skip setup, the site still looks and behaves perfectly — the demo card just
shows a "model not installed yet" message. See **[OFFLINE-STT.md](OFFLINE-STT.md)**
for the full architecture and the privacy guarantee.

## How the offline pipeline works

1. `getUserMedia` captures the mic in the page.
2. Audio is downsampled to 16 kHz mono `Float32` in-browser.
3. Transformers.js runs Whisper tiny.en in WebAssembly, hard-configured to stay local:

   ```js
   env.allowRemoteModels = false;             // never fetch models remotely
   env.localModelPath = './models/';          // weights load from this origin
   env.backends.onnx.wasm.wasmPaths = './js/vendor/';
   ```
4. The transcript appears with a **Copy** button; the audio buffer is discarded.

## Embed on your own site

Host this folder (after running setup) on your domain and add:

```html
<script>
  window.VOICEFLOW_CONFIG = { position: "bottom-right", title: "Dictate", theme: "auto" };
</script>
<script src="/embed/voiceflow-embed.js" defer></script>
```

A floating dictation button appears. It uses the same on-device pipeline and shows
a friendly setup message if the model assets aren't hosted alongside it.

## Files

```
Website/
  index.html               # landing page + inline dictation demo (signature: the voice ribbon)
  css/style.css            # "liquid voice" design system — dark + light, responsive
  js/voice-agent.js        # inline offline dictation engine + animated ribbon
  js/app.js                # copy snippet / download helpers
  js/vendor/               # Transformers.js + ONNX WASM (populated by setup)
  models/whisper-tiny.en/  # local Whisper model (populated by setup)
  embed/voiceflow-embed.js # self-contained floating dictation widget
  setup-offline-stt.sh     # one-time downloader for the runtime + model
  OFFLINE-STT.md           # setup + privacy details
```

## Privacy

Open your browser's **Network tab** and dictate: you'll see zero requests. The
runtime, WASM, and model are all same-origin; a strict Content-Security-Policy in
`index.html` blocks any remote origin. Your voice stays yours.

---
Built for Kenneth Aman — VoiceFlow
