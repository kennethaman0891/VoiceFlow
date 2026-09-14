/**
 * VoiceFlow embed — self-contained floating on-device dictation button.
 *
 *   <script>window.VOICEFLOW_CONFIG = { position:"bottom-right", title:"Dictate", theme:"auto" }</script>
 *   <script src="/embed/voiceflow-embed.js" defer></script>
 *
 * Drops a floating button on any page. Tap it, speak, and the words are
 * transcribed by a local Whisper model running in the visitor's browser
 * (Transformers.js + WASM). No audio, transcript, or telemetry leaves the
 * device: there is no backend, no API, and no third-party service.
 *
 * The library and model are loaded from the SAME ORIGIN as this script
 * (js/vendor/ and models/). If those assets haven't been installed
 * (see setup-offline-stt.sh) the widget shows a friendly setup message and
 * never breaks the host page.
 */
(function () {
  'use strict';

  if (window.__voiceflowEmbedLoaded) return;
  window.__voiceflowEmbedLoaded = true;

  var CFG = Object.assign({
    position: 'bottom-right',              // 'bottom-right' | 'bottom-left'
    title: 'Dictate',
    subtitle: 'Speak — it types, on your device',
    theme: 'auto'                          // 'auto' | 'dark' | 'light'
  }, window.VOICEFLOW_CONFIG || {});

  // --- Resolve local asset paths relative to THIS script's origin -------------
  var SCRIPT_SRC = (document.currentScript && document.currentScript.src) || '';
  var BASE = '';
  try { BASE = new URL('../', SCRIPT_SRC).href; } catch (e) { BASE = ''; } // /embed/ -> site root
  var LIB_URL = BASE ? BASE + 'js/vendor/transformers.min.js' : './js/vendor/transformers.min.js';
  var MODEL_ROOT = BASE ? BASE + 'models/' : './models/';
  var WASM_PATH = BASE ? BASE + 'js/vendor/' : './js/vendor/';
  var MODEL_PROBE = MODEL_ROOT + 'whisper-tiny.en/config.json';
  var MODEL_ID = 'whisper-tiny.en';

  var NOT_INSTALLED =
    'On-device model not installed yet. Run <code>./setup-offline-stt.sh</code> ' +
    'and host <code>js/vendor/</code> + <code>models/</code> next to this script.';

  var reduceMotion = !!(window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches);
  var right = String(CFG.position).indexOf('left') === -1;

  // --- State ---
  var asr = null, assetsReady = null, recording = false, busy = false, dictated = '';
  var audioCtx = null, mediaStream = null, sourceNode = null, processor = null, analyser = null, muteGain = null;
  var pcmChunks = [], recordRate = 16000;

  // ---------------------------------------------------------------------------
  // Styles (scoped under #vf-embed; supports dark + light)
  // ---------------------------------------------------------------------------
  var CSS = [
    '#vf-embed,#vf-embed *{box-sizing:border-box}',
    '#vf-embed{position:fixed;bottom:22px;' + (right ? 'right:22px' : 'left:22px') + ';z-index:2147483000;',
      'font-family:-apple-system,"SF Pro Display","Segoe UI Variable","Segoe UI",system-ui,sans-serif;',
      '--vf-flow:linear-gradient(100deg,#6D8BFF 0%,#A56BFF 52%,#59D6C6 100%);',
      '--vf-panel:#141826;--vf-inset:#0E1119;--vf-text:#EEF1FA;--vf-text2:#9BA3B7;--vf-line:rgba(255,255,255,.12);--vf-live:#59D6C6}',
    '#vf-embed[data-theme="light"]{--vf-panel:#fff;--vf-inset:#F0F2F8;--vf-text:#0B0D14;--vf-text2:#545C72;--vf-line:rgba(11,13,20,.12);--vf-live:#12A594}',
    '#vf-launch{width:58px;height:58px;border-radius:50%;border:none;cursor:pointer;display:grid;place-items:center;color:#fff;background:var(--vf-flow);box-shadow:0 14px 34px rgba(124,134,255,.45);transition:transform .16s ease,box-shadow .2s ease}',
    '#vf-launch:hover{transform:translateY(-2px) scale(1.03)}',
    '#vf-launch:focus-visible{outline:3px solid #7C86FF;outline-offset:3px}',
    '#vf-embed.is-recording #vf-launch{animation:vfRec 1.7s ease-in-out infinite}',
    '@keyframes vfRec{0%,100%{box-shadow:0 14px 34px rgba(124,134,255,.45)}50%{box-shadow:0 14px 46px rgba(89,214,198,.6)}}',
    '#vf-panel{position:absolute;bottom:72px;' + (right ? 'right:0' : 'left:0') + ';width:328px;max-width:calc(100vw - 32px);',
      'background:var(--vf-panel);border:1px solid var(--vf-line);border-radius:20px;overflow:hidden;box-shadow:0 24px 60px rgba(0,0,0,.5);display:none}',
    '#vf-embed.is-open #vf-panel{display:block}',
    '#vf-head{display:flex;align-items:center;gap:10px;padding:13px 15px;border-bottom:1px solid var(--vf-line)}',
    '#vf-head h4{margin:0;font-size:14px;font-weight:650;color:var(--vf-text);letter-spacing:-.01em}',
    '#vf-head p{margin:1px 0 0;font-size:12px;color:var(--vf-text2)}',
    '#vf-x{margin-left:auto;width:30px;height:30px;border-radius:50%;border:1px solid var(--vf-line);background:transparent;color:var(--vf-text2);cursor:pointer;font-size:15px;line-height:1;display:grid;place-items:center}',
    '#vf-x:hover{color:var(--vf-text)}',
    '#vf-stage{position:relative;height:64px;background:radial-gradient(120% 150% at 50% 130%,rgba(124,134,255,.18),transparent 60%),var(--vf-inset)}',
    '#vf-canvas{position:absolute;inset:0;width:100%;height:100%}',
    '#vf-body{padding:15px}',
    '#vf-transcript{min-height:60px;background:var(--vf-inset);border:1px solid var(--vf-line);border-radius:13px;padding:11px 13px;',
      'font-family:ui-monospace,"SF Mono","Cascadia Code",Menlo,Consolas,monospace;font-size:13px;line-height:1.55;color:var(--vf-text);white-space:pre-wrap;word-break:break-word}',
    '#vf-transcript[data-empty="true"]{color:var(--vf-text2)}',
    '#vf-controls{display:flex;gap:9px;margin-top:13px}',
    '.vf-btn{appearance:none;font-family:inherit;font-weight:600;font-size:14px;min-height:44px;padding:10px 16px;border-radius:999px;cursor:pointer;border:1px solid transparent;display:inline-flex;align-items:center;justify-content:center;gap:8px;transition:transform .16s ease,box-shadow .2s ease,border-color .2s ease}',
    '.vf-btn:focus-visible{outline:3px solid #7C86FF;outline-offset:2px}',
    '#vf-rec{flex:1 1 auto;color:#fff;background:var(--vf-flow);box-shadow:0 12px 30px rgba(124,134,255,.4)}',
    '#vf-rec:hover{transform:translateY(-1px)}',
    '#vf-rec .vf-dot{width:12px;height:12px;border-radius:50%;background:#fff;box-shadow:0 0 0 4px rgba(255,255,255,.22);transition:border-radius .18s ease}',
    '#vf-embed.is-recording #vf-rec{background:color-mix(in srgb,var(--vf-live) 22%,var(--vf-panel));color:var(--vf-text);box-shadow:0 0 0 1px color-mix(in srgb,var(--vf-live) 60%,transparent)}',
    '#vf-embed.is-recording #vf-rec .vf-dot{border-radius:3px;background:var(--vf-live);box-shadow:0 0 0 4px color-mix(in srgb,var(--vf-live) 22%,transparent)}',
    '#vf-copy{background:transparent;border-color:var(--vf-line);color:var(--vf-text)}',
    '#vf-copy:hover{border-color:#7C86FF}',
    '#vf-status{margin:12px 0 0;text-align:center;font-family:ui-monospace,Menlo,Consolas,monospace;font-size:12px;color:var(--vf-text2);min-height:1.1em}',
    '#vf-status.is-live{color:var(--vf-live)}#vf-status.is-error{color:#FF8F8F}',
    '#vf-note{margin-top:12px;padding:11px 13px;border:1px solid var(--vf-line);border-left:3px solid #7C86FF;border-radius:12px;background:rgba(124,134,255,.12);color:var(--vf-text);font-size:12.5px;line-height:1.55}',
    '#vf-note code{font-family:ui-monospace,Menlo,Consolas,monospace;font-size:11.5px;background:rgba(124,134,255,.16);padding:1px 5px;border-radius:5px}',
    '#vf-foot{padding:9px 15px;border-top:1px solid var(--vf-line);font-size:11px;color:var(--vf-text2);display:flex;justify-content:space-between;align-items:center}',
    '@media (prefers-reduced-motion: reduce){#vf-launch,#vf-rec,#vf-embed.is-recording #vf-launch{transition:none;animation:none}}'
  ].join('\n');

  // ---------------------------------------------------------------------------
  // Build DOM (no inline scripts / handlers; text set via textContent)
  // ---------------------------------------------------------------------------
  function svg(markup) {
    var wrap = document.createElement('span');
    wrap.innerHTML = markup; // static, trusted markup only
    return wrap.firstChild;
  }

  var MIC_SVG = '<svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="2" aria-hidden="true"><path d="M12 2a3 3 0 0 0-3 3v7a3 3 0 0 0 6 0V5a3 3 0 0 0-3-3z"/><path d="M19 10a7 7 0 0 1-14 0"/><line x1="12" y1="19" x2="12" y2="22"/></svg>';

  var root = document.createElement('div');
  root.id = 'vf-embed';

  function resolveTheme() {
    if (CFG.theme === 'light' || CFG.theme === 'dark') return CFG.theme;
    return (window.matchMedia && window.matchMedia('(prefers-color-scheme: light)').matches) ? 'light' : 'dark';
  }
  root.setAttribute('data-theme', resolveTheme());
  if (CFG.theme === 'auto' && window.matchMedia) {
    var mq = window.matchMedia('(prefers-color-scheme: light)');
    var onThemeChange = function () { root.setAttribute('data-theme', mq.matches ? 'light' : 'dark'); };
    if (mq.addEventListener) mq.addEventListener('change', onThemeChange);
    else if (mq.addListener) mq.addListener(onThemeChange);
  }

  var panel = document.createElement('div');
  panel.id = 'vf-panel';
  panel.setAttribute('role', 'dialog');
  panel.setAttribute('aria-label', 'VoiceFlow dictation');

  // Header
  var head = document.createElement('div');
  head.id = 'vf-head';
  var mark = svg('<svg viewBox="0 0 26 26" width="26" height="26" aria-hidden="true"><defs><linearGradient id="vfEmbedGrad" x1="0" y1="0" x2="1" y2="1"><stop offset="0%" stop-color="#6D8BFF"/><stop offset="52%" stop-color="#A56BFF"/><stop offset="100%" stop-color="#59D6C6"/></linearGradient></defs><rect x="0.5" y="0.5" width="25" height="25" rx="7.5" fill="url(#vfEmbedGrad)"/><path d="M4 15 C 7 9, 10 9, 13 13 S 19 17, 22 10.5" fill="none" stroke="#fff" stroke-width="2.2" stroke-linecap="round" opacity="0.95"/></svg>');
  var headText = document.createElement('div');
  var h4 = document.createElement('h4'); h4.textContent = CFG.title;
  var sub = document.createElement('p'); sub.textContent = CFG.subtitle;
  headText.appendChild(h4); headText.appendChild(sub);
  var closeBtn = document.createElement('button');
  closeBtn.id = 'vf-x'; closeBtn.type = 'button'; closeBtn.setAttribute('aria-label', 'Close'); closeBtn.textContent = '✕';
  head.appendChild(mark); head.appendChild(headText); head.appendChild(closeBtn);

  // Stage + canvas
  var stage = document.createElement('div'); stage.id = 'vf-stage';
  var canvas = document.createElement('canvas'); canvas.id = 'vf-canvas'; canvas.setAttribute('aria-hidden', 'true');
  stage.appendChild(canvas);

  // Body
  var body = document.createElement('div'); body.id = 'vf-body';
  var transcript = document.createElement('div');
  transcript.id = 'vf-transcript';
  transcript.setAttribute('role', 'region');
  transcript.setAttribute('aria-live', 'polite');
  transcript.setAttribute('aria-label', 'Transcript');
  transcript.setAttribute('data-empty', 'true');
  transcript.textContent = 'Your words will appear here.';

  var controls = document.createElement('div'); controls.id = 'vf-controls';
  var recBtn = document.createElement('button');
  recBtn.id = 'vf-rec'; recBtn.className = 'vf-btn'; recBtn.type = 'button'; recBtn.setAttribute('aria-label', 'Start dictation');
  var recDot = document.createElement('span'); recDot.className = 'vf-dot'; recDot.setAttribute('aria-hidden', 'true');
  var recLabel = document.createElement('span'); recLabel.textContent = 'Start';
  recBtn.appendChild(recDot); recBtn.appendChild(recLabel);
  var copyBtn = document.createElement('button');
  copyBtn.id = 'vf-copy'; copyBtn.className = 'vf-btn'; copyBtn.type = 'button'; copyBtn.textContent = 'Copy'; copyBtn.hidden = true;
  controls.appendChild(recBtn); controls.appendChild(copyBtn);

  var status = document.createElement('p'); status.id = 'vf-status'; status.textContent = 'Ready when you are.';
  var note = document.createElement('div'); note.id = 'vf-note'; note.hidden = true;

  body.appendChild(transcript); body.appendChild(controls); body.appendChild(status); body.appendChild(note);

  var foot = document.createElement('div'); foot.id = 'vf-foot';
  var footL = document.createElement('span'); footL.textContent = 'On-device · nothing leaves your device';
  foot.appendChild(footL);

  panel.appendChild(head); panel.appendChild(stage); panel.appendChild(body); panel.appendChild(foot);

  var launch = document.createElement('button');
  launch.id = 'vf-launch'; launch.type = 'button'; launch.setAttribute('aria-label', 'Open VoiceFlow dictation');
  launch.appendChild(svg(MIC_SVG));

  root.appendChild(panel); root.appendChild(launch);

  function mount() {
    var style = document.createElement('style');
    style.textContent = CSS;
    document.head.appendChild(style);
    document.body.appendChild(root);
    init();
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', mount);
  else mount();

  // ---------------------------------------------------------------------------
  // Behaviour
  // ---------------------------------------------------------------------------
  function setStatus(text, cls) { status.textContent = text; status.className = cls || ''; }
  function showNote(html) { note.innerHTML = html; note.hidden = false; }
  function hideNote() { note.hidden = true; note.innerHTML = ''; }

  function renderTranscript() {
    if (!dictated) {
      transcript.setAttribute('data-empty', 'true');
      transcript.textContent = 'Your words will appear here.';
      copyBtn.hidden = true;
      return;
    }
    transcript.setAttribute('data-empty', 'false');
    transcript.textContent = dictated; // user text via textContent — never markup
    copyBtn.hidden = false;
  }
  function appendTranscript(text) {
    var t = (text || '').trim();
    if (!t) return;
    dictated = dictated ? (dictated.replace(/\s+$/, '') + ' ' + t) : t;
    renderTranscript();
  }

  function probeAssets() {
    if (assetsReady !== null) return Promise.resolve(assetsReady);
    return fetch(MODEL_PROBE, { method: 'GET', cache: 'force-cache' })
      .then(function (r) { assetsReady = r.ok; return assetsReady; })
      .catch(function () { assetsReady = false; return false; });
  }

  function ensureASR() {
    if (asr) return Promise.resolve(asr);
    return import(LIB_URL).then(function (lib) {
      var env = lib.env;
      env.allowRemoteModels = false;
      env.localModelPath = MODEL_ROOT;
      try { env.backends.onnx.wasm.wasmPaths = WASM_PATH; } catch (e) {}
      return lib.pipeline('automatic-speech-recognition', MODEL_ID, {
        quantized: true,
        progress_callback: function (p) {
          if (p && p.status === 'progress' && typeof p.progress === 'number') {
            setStatus('Loading model… ' + Math.round(p.progress) + '%', '');
          }
        }
      });
    }).then(function (pipe) { asr = pipe; return pipe; });
  }

  function micSupported() { return !!(navigator.mediaDevices && navigator.mediaDevices.getUserMedia); }

  function startRecording() {
    return navigator.mediaDevices.getUserMedia({
      audio: { channelCount: 1, echoCancellation: true, noiseSuppression: true, autoGainControl: true }
    }).then(function (stream) {
      mediaStream = stream;
      var AC = window.AudioContext || window.webkitAudioContext;
      audioCtx = new AC();
      recordRate = audioCtx.sampleRate;
      sourceNode = audioCtx.createMediaStreamSource(stream);
      analyser = audioCtx.createAnalyser();
      analyser.fftSize = 1024; analyser.smoothingTimeConstant = 0.82;
      sourceNode.connect(analyser);
      processor = audioCtx.createScriptProcessor(4096, 1, 1);
      pcmChunks = [];
      processor.onaudioprocess = function (e) {
        if (!recording) return;
        pcmChunks.push(new Float32Array(e.inputBuffer.getChannelData(0)));
      };
      sourceNode.connect(processor);
      muteGain = audioCtx.createGain(); muteGain.gain.value = 0;
      processor.connect(muteGain); muteGain.connect(audioCtx.destination);
      if (audioCtx.state === 'suspended') { try { audioCtx.resume(); } catch (e) {} }
      recording = true;
    });
  }

  function teardownAudio() {
    try { if (processor) { processor.disconnect(); processor.onaudioprocess = null; } } catch (e) {}
    try { if (sourceNode) sourceNode.disconnect(); } catch (e) {}
    try { if (analyser) analyser.disconnect(); } catch (e) {}
    try { if (muteGain) muteGain.disconnect(); } catch (e) {}
    if (mediaStream) mediaStream.getTracks().forEach(function (t) { t.stop(); });
    var ctx = audioCtx;
    audioCtx = mediaStream = sourceNode = processor = analyser = muteGain = null;
    if (ctx) { try { ctx.close(); } catch (e) {} }
  }

  function downsampleTo16k(buffer, inputRate) {
    var target = 16000;
    if (inputRate === target) return buffer;
    var ratio = inputRate / target;
    var newLen = Math.round(buffer.length / ratio);
    var out = new Float32Array(newLen);
    for (var i = 0; i < newLen; i++) {
      var idx = i * ratio, i0 = Math.floor(idx), i1 = Math.min(i0 + 1, buffer.length - 1), frac = idx - i0;
      out[i] = buffer[i0] * (1 - frac) + buffer[i1] * frac;
    }
    return out;
  }

  function stopAndTranscribe() {
    recording = false;
    var rate = recordRate, i, total = 0;
    for (i = 0; i < pcmChunks.length; i++) total += pcmChunks[i].length;
    var merged = new Float32Array(total), off = 0;
    for (i = 0; i < pcmChunks.length; i++) { merged.set(pcmChunks[i], off); off += pcmChunks[i].length; }
    pcmChunks = [];
    teardownAudio();
    if (total < rate * 0.25) { setStatus('Didn’t catch that — hold a little longer.', ''); return Promise.resolve(); }
    var samples = downsampleTo16k(merged, rate);
    setStatus('Transcribing on your device…', 'is-live');
    return Promise.resolve(asr(samples)).then(function (out) {
      var text = '';
      if (out) {
        if (typeof out.text === 'string') text = out.text;
        else if (Array.isArray(out) && out[0] && typeof out[0].text === 'string') text = out[0].text;
      }
      appendTranscript(text);
      setStatus(text.trim() ? 'Done — copy it, or keep going.' : 'No speech detected — try again.', '');
    });
  }

  function micErrorMessage(err) {
    var n = err && err.name;
    if (n === 'NotAllowedError' || n === 'SecurityError') return 'Microphone blocked — allow access, then try again.';
    if (n === 'NotFoundError' || n === 'OverconstrainedError') return 'No microphone found.';
    return 'Couldn’t start the microphone.';
  }

  function onRec() {
    if (busy) return;
    if (recording) {
      busy = true;
      root.classList.remove('is-recording');
      recBtn.setAttribute('aria-label', 'Start dictation');
      recLabel.textContent = 'Start';
      setStatus('Transcribing on your device…', 'is-live');
      stopAndTranscribe().catch(function (e) {
        console.warn('[VoiceFlow embed] transcription failed:', e);
        teardownAudio();
        setStatus('Transcription failed — try again.', 'is-error');
      }).then(function () { busy = false; });
      return;
    }
    busy = true;
    hideNote();
    probeAssets().then(function (ready) {
      if (!ready) { showNote(NOT_INSTALLED); setStatus('Model not installed yet.', ''); busy = false; return; }
      if (!micSupported()) { setStatus('This browser can’t access the microphone.', 'is-error'); busy = false; return; }
      if (!window.isSecureContext) { setStatus('Needs https or localhost for the mic.', 'is-error'); busy = false; return; }

      var loadStep = Promise.resolve();
      if (!asr) {
        recBtn.disabled = true; recLabel.textContent = 'Loading…';
        setStatus('Loading model… first run only', '');
        loadStep = ensureASR().catch(function (e) {
          console.warn('[VoiceFlow embed] model load failed:', e);
          showNote(NOT_INSTALLED);
          setStatus('Couldn’t load the local model.', 'is-error');
          throw e;
        });
      }
      loadStep.then(function () {
        recBtn.disabled = false;
        return startRecording();
      }).then(function () {
        root.classList.add('is-recording');
        recBtn.setAttribute('aria-label', 'Stop dictation');
        recLabel.textContent = 'Stop';
        setStatus('Listening… speak now', 'is-live');
        busy = false;
      }).catch(function (e) {
        recBtn.disabled = false;
        recLabel.textContent = 'Start';
        if (asr) setStatus(micErrorMessage(e), 'is-error');
        teardownAudio();
        busy = false;
      });
    });
  }

  // --- Ribbon (compact) ---
  var ctx2d = canvas.getContext('2d');
  var W = 0, H = 0, dpr = 1, grad = null, amp = 0, raf = null, t0 = 0;
  var LAYERS = [
    { a: 0.55, f: 1.2, s: 0.6, w: 2.2, o: 0.95, ph: 0 },
    { a: 0.9, f: 1.9, s: -0.9, w: 1.4, o: 0.45, ph: 1.6 }
  ];
  function sizeCanvas() {
    var r = canvas.getBoundingClientRect();
    dpr = Math.min(window.devicePixelRatio || 1, 2);
    W = Math.max(1, Math.round(r.width)); H = Math.max(1, Math.round(r.height));
    canvas.width = Math.round(W * dpr); canvas.height = Math.round(H * dpr);
    ctx2d.setTransform(dpr, 0, 0, dpr, 0, 0);
    grad = ctx2d.createLinearGradient(0, 0, W, 0);
    grad.addColorStop(0, '#6D8BFF'); grad.addColorStop(0.52, '#A56BFF'); grad.addColorStop(1, '#59D6C6');
  }
  function micAmp() {
    if (!analyser) return 0;
    var buf = new Uint8Array(analyser.fftSize);
    analyser.getByteTimeDomainData(buf);
    var sum = 0;
    for (var i = 0; i < buf.length; i++) { var v = (buf[i] - 128) / 128; sum += v * v; }
    return Math.min(1, Math.sqrt(sum / buf.length) * 3.4);
  }
  function draw(t, a) {
    if (!W || !H) return;
    ctx2d.clearRect(0, 0, W, H);
    var mid = H * 0.5, idle = 0.06, react = 0.34, step = Math.max(2, Math.floor(W / 90));
    ctx2d.lineCap = 'round'; ctx2d.strokeStyle = grad;
    for (var l = 0; l < LAYERS.length; l++) {
      var L = LAYERS[l], A = (idle + a * react) * L.a * H;
      ctx2d.beginPath();
      for (var x = 0; x <= W; x += step) {
        var px = x / W, env = Math.sin(Math.PI * px);
        var y = mid + Math.sin(px * Math.PI * 2 * L.f + t * L.s * Math.PI + L.ph) * A * env;
        if (x === 0) ctx2d.moveTo(x, y); else ctx2d.lineTo(x, y);
      }
      ctx2d.globalAlpha = L.o; ctx2d.lineWidth = L.w; ctx2d.stroke();
    }
    ctx2d.globalAlpha = 1;
  }
  function loop(now) {
    var t = (now - t0) / 1000;
    amp += ((recording ? micAmp() : 0) - amp) * 0.12;
    draw(t, amp);
    raf = window.requestAnimationFrame(loop);
  }
  function startRibbon() {
    sizeCanvas();
    if (reduceMotion) { draw(0, 0); return; }
    if (raf == null) { t0 = window.performance ? performance.now() : Date.now(); raf = window.requestAnimationFrame(loop); }
  }
  function stopRibbon() { if (raf != null) { window.cancelAnimationFrame(raf); raf = null; } }

  function init() {
    launch.addEventListener('click', function () {
      var open = root.classList.toggle('is-open');
      if (open) startRibbon(); else stopRibbon();
    });
    closeBtn.addEventListener('click', function () { root.classList.remove('is-open'); stopRibbon(); });
    recBtn.addEventListener('click', onRec);
    copyBtn.addEventListener('click', function () {
      if (!dictated) return;
      var done = function () { var p = copyBtn.textContent; copyBtn.textContent = 'Copied'; setTimeout(function () { copyBtn.textContent = p || 'Copy'; }, 1400); };
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(dictated).then(done).catch(fallbackCopy);
      } else { fallbackCopy(); }
      function fallbackCopy() {
        try {
          var ta = document.createElement('textarea');
          ta.value = dictated;
          ta.setAttribute('readonly', '');
          ta.style.cssText = 'position:absolute;left:-9999px';
          document.body.appendChild(ta);
          ta.select();
          document.execCommand('copy');
          ta.remove();
          done();
        } catch (e) { /* clipboard unavailable */ done(); }
      }
    });
    document.addEventListener('keydown', function (e) { if (e.key === 'Escape') root.classList.remove('is-open'); });

    if ('ResizeObserver' in window) { new ResizeObserver(function () { sizeCanvas(); if (reduceMotion) draw(0, 0); }).observe(canvas); }
    else window.addEventListener('resize', function () { sizeCanvas(); if (reduceMotion) draw(0, 0); });

    document.addEventListener('visibilitychange', function () {
      if (reduceMotion || !root.classList.contains('is-open')) return;
      if (document.hidden) stopRibbon();
      else if (raf == null) { t0 = window.performance ? performance.now() : Date.now(); raf = window.requestAnimationFrame(loop); }
    });

    (window.requestIdleCallback || function (fn) { setTimeout(fn, 500); })(function () {
      probeAssets().then(function (ready) { if (!ready) { showNote(NOT_INSTALLED); setStatus('Model not installed yet.', ''); } });
    });
  }
})();
