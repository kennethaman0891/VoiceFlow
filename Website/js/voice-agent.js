/**
 * VoiceFlow — inline offline dictation demo.
 *
 * Mic -> local Whisper (Transformers.js, WASM) -> transcript + Copy.
 *
 * Everything is same-origin and offline:
 *   - the library is imported from ./js/vendor/transformers.min.js (NOT a CDN)
 *   - the model loads from ./models/whisper-tiny.en/ (allowRemoteModels = false)
 *   - the ONNX WASM binaries load from ./js/vendor/
 * No audio, transcript, or telemetry ever leaves the device. There is no backend.
 *
 * If the vendor/model assets aren't installed yet (see setup-offline-stt.sh) the
 * card shows a friendly setup message and the rest of the page is unaffected.
 */
(function () {
  'use strict';

  var recordBtn = document.getElementById('vf-record');
  var canvas = document.getElementById('vf-ribbon');
  if (!recordBtn || !canvas) return; // demo not present on this page

  var recordLabel = recordBtn.querySelector('.record-label');
  var transcriptEl = document.getElementById('vf-transcript');
  var copyBtn = document.getElementById('vf-copy');
  var statusEl = document.getElementById('vf-status');
  var noteEl = document.getElementById('vf-note');
  var heroDemoBtn = document.getElementById('heroDemoBtn');

  // --- Local, same-origin asset locations (no remote origins) ---
  var LIB_URL = './js/vendor/transformers.min.js';
  var MODEL_ID = 'whisper-tiny.en';
  var MODEL_PROBE = './models/whisper-tiny.en/config.json';

  var NOT_INSTALLED =
    'Offline dictation model not installed yet — run ' +
    '<code>./setup-offline-stt.sh</code> (one-time, ~40&nbsp;MB) to enable ' +
    'on-device transcription. Everything else on the page works without it.';

  var reduceMotion = !!(window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches);

  // --- State ---
  var asr = null;            // the ASR pipeline once loaded
  var assetsReady = null;    // null unknown / true / false
  var recording = false;
  var busy = false;          // guards overlapping clicks during load/transcribe
  var dictated = '';         // accumulated transcript

  // Audio graph
  var audioCtx = null, mediaStream = null, sourceNode = null,
      processor = null, analyser = null, muteGain = null;
  var pcmChunks = [], recordRate = 16000;

  // ---------------------------------------------------------------------------
  // UI helpers
  // ---------------------------------------------------------------------------
  function setStatus(text, cls) {
    if (!statusEl) return;
    statusEl.textContent = text;
    statusEl.className = 'demo-status' + (cls ? ' ' + cls : '');
  }
  function setLabel(text) { if (recordLabel) recordLabel.textContent = text; }
  function showNote(html) { if (!noteEl) return; noteEl.innerHTML = html; noteEl.hidden = false; }
  function hideNote() { if (!noteEl) return; noteEl.hidden = true; noteEl.innerHTML = ''; }

  // User-generated text goes in via textContent — never innerHTML — so it can
  // never be interpreted as markup.
  function renderTranscript() {
    if (!transcriptEl) return;
    if (!dictated) {
      transcriptEl.setAttribute('data-empty', 'true');
      transcriptEl.textContent = '';
      var ph = document.createElement('span');
      ph.className = 'transcript-placeholder';
      ph.textContent = 'Your words will appear here.';
      transcriptEl.appendChild(ph);
      if (copyBtn) copyBtn.hidden = true;
      return;
    }
    transcriptEl.setAttribute('data-empty', 'false');
    transcriptEl.textContent = dictated;
    if (copyBtn) copyBtn.hidden = false;
  }
  function appendTranscript(text) {
    var t = (text || '').trim();
    if (!t) return;
    dictated = dictated ? (dictated.replace(/\s+$/, '') + ' ' + t) : t;
    renderTranscript();
  }

  // ---------------------------------------------------------------------------
  // Offline model loading
  // ---------------------------------------------------------------------------
  function probeAssets() {
    if (assetsReady !== null) return Promise.resolve(assetsReady);
    // Tiny same-origin GET of the model config just to know if setup has run.
    return fetch(MODEL_PROBE, { method: 'GET', cache: 'force-cache' })
      .then(function (r) { assetsReady = r.ok; return assetsReady; })
      .catch(function () { assetsReady = false; return false; });
  }

  function ensureASR() {
    if (asr) return Promise.resolve(asr);
    // Dynamic import of the LOCAL ES module (resolved against the page origin).
    return import(LIB_URL).then(function (lib) {
      var pipeline = lib.pipeline, env = lib.env;
      // Hard-lock the library to on-device operation.
      env.allowRemoteModels = false;
      env.localModelPath = './models/';
      try { env.backends.onnx.wasm.wasmPaths = './js/vendor/'; } catch (e) {}
      return pipeline('automatic-speech-recognition', MODEL_ID, {
        quantized: true,
        progress_callback: function (p) {
          if (!p) return;
          if (p.status === 'progress' && typeof p.progress === 'number') {
            setStatus('Loading model… ' + Math.round(p.progress) + '% (first run only)');
          } else if (p.status === 'ready') {
            setStatus('Model ready.');
          }
        }
      });
    }).then(function (pipe) { asr = pipe; return pipe; });
  }

  // ---------------------------------------------------------------------------
  // Audio capture (Web Audio) + downsample to 16 kHz mono Float32
  // ---------------------------------------------------------------------------
  function micSupported() {
    return !!(navigator.mediaDevices && navigator.mediaDevices.getUserMedia);
  }

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
      analyser.fftSize = 1024;
      analyser.smoothingTimeConstant = 0.82;
      sourceNode.connect(analyser);

      // ScriptProcessor keeps this dependency-free (no separate worklet file to
      // host) and works across browsers for a short dictation clip.
      processor = audioCtx.createScriptProcessor(4096, 1, 1);
      pcmChunks = [];
      processor.onaudioprocess = function (e) {
        if (!recording) return;
        pcmChunks.push(new Float32Array(e.inputBuffer.getChannelData(0)));
      };
      sourceNode.connect(processor);
      // Route the processor to a muted gain node so it pulls audio without
      // echoing the mic to the speakers.
      muteGain = audioCtx.createGain();
      muteGain.gain.value = 0;
      processor.connect(muteGain);
      muteGain.connect(audioCtx.destination);

      if (audioCtx.state === 'suspended') { try { audioCtx.resume(); } catch (e) {} }
      recording = true;
    });
  }

  function teardownAudio() {
    try { if (processor) { processor.disconnect(); processor.onaudioprocess = null; } } catch (e) {}
    try { if (sourceNode) sourceNode.disconnect(); } catch (e) {}
    try { if (analyser) analyser.disconnect(); } catch (e) {}
    try { if (muteGain) muteGain.disconnect(); } catch (e) {}
    if (mediaStream) { mediaStream.getTracks().forEach(function (t) { t.stop(); }); }
    var ctx = audioCtx;
    audioCtx = null; mediaStream = null; sourceNode = null;
    processor = null; analyser = null; muteGain = null;
    if (ctx) { try { ctx.close(); } catch (e) {} }
  }

  function downsampleTo16k(buffer, inputRate) {
    var target = 16000;
    if (inputRate === target) return buffer;
    var ratio = inputRate / target;
    var newLen = Math.round(buffer.length / ratio);
    var out = new Float32Array(newLen);
    for (var i = 0; i < newLen; i++) {
      var idx = i * ratio;
      var i0 = Math.floor(idx);
      var i1 = Math.min(i0 + 1, buffer.length - 1);
      var frac = idx - i0;
      out[i] = buffer[i0] * (1 - frac) + buffer[i1] * frac;
    }
    return out;
  }

  function stopAndTranscribe() {
    recording = false;
    var rate = recordRate;

    var total = 0, i;
    for (i = 0; i < pcmChunks.length; i++) total += pcmChunks[i].length;
    var merged = new Float32Array(total), off = 0;
    for (i = 0; i < pcmChunks.length; i++) { merged.set(pcmChunks[i], off); off += pcmChunks[i].length; }
    pcmChunks = [];

    teardownAudio(); // releases the mic immediately

    if (total < rate * 0.25) { // less than ~0.25s captured
      setStatus('Didn’t catch that — hold the button a little longer.');
      return Promise.resolve();
    }

    var samples = downsampleTo16k(merged, rate);
    setStatus('Transcribing on your device…', 'is-live');
    // whisper-tiny.en is English-only; no language/task tokens needed.
    return Promise.resolve(asr(samples)).then(function (out) {
      var text = '';
      if (out) {
        if (typeof out.text === 'string') text = out.text;
        else if (Array.isArray(out) && out[0] && typeof out[0].text === 'string') text = out[0].text;
      }
      appendTranscript(text);
      setStatus(text.trim() ? 'Done — copy it, or keep dictating.' : 'No speech detected — try again.');
    });
  }

  // ---------------------------------------------------------------------------
  // Error messaging
  // ---------------------------------------------------------------------------
  function micErrorMessage(err) {
    var name = err && err.name;
    if (name === 'NotAllowedError' || name === 'SecurityError') {
      return 'Microphone blocked — allow access from your browser’s address bar, then try again.';
    }
    if (name === 'NotFoundError' || name === 'OverconstrainedError') {
      return 'No microphone found — connect one and try again.';
    }
    return 'Couldn’t start the microphone (' + (name || 'unknown error') + ').';
  }

  // ---------------------------------------------------------------------------
  // Main record toggle
  // ---------------------------------------------------------------------------
  function stopUI() {
    recordBtn.classList.remove('is-recording');
    recordBtn.setAttribute('aria-label', 'Start dictation');
    setLabel('Start dictation');
  }
  function recordUI() {
    recordBtn.classList.add('is-recording');
    recordBtn.setAttribute('aria-label', 'Stop dictation');
    setLabel('Stop');
  }

  function onRecordClick() {
    if (busy) return;

    // Currently recording -> stop + transcribe
    if (recording) {
      busy = true;
      stopUI();
      setStatus('Transcribing on your device…', 'is-live');
      stopAndTranscribe().catch(function (e) {
        console.warn('[VoiceFlow] transcription failed:', e);
        teardownAudio();
        setStatus('Transcription failed — please try again.', 'is-error');
      }).then(function () { busy = false; });
      return;
    }

    // Starting fresh
    busy = true;
    hideNote();
    probeAssets().then(function (ready) {
      if (!ready) { showNote(NOT_INSTALLED); setStatus('Model not installed yet.'); busy = false; return; }
      if (!micSupported()) { setStatus('This browser can’t access the microphone.', 'is-error'); busy = false; return; }
      if (!window.isSecureContext) { setStatus('Serve the site over https or localhost to use the mic.', 'is-error'); busy = false; return; }

      var loadStep = Promise.resolve();
      if (!asr) {
        recordBtn.classList.add('is-loading');
        recordBtn.disabled = true;
        setLabel('Loading model…');
        setStatus('Loading model… first run only');
        loadStep = ensureASR().catch(function (e) {
          console.warn('[VoiceFlow] model load failed:', e);
          showNote(NOT_INSTALLED);
          setStatus('Couldn’t load the local model.', 'is-error');
          throw e;
        });
      }

      loadStep.then(function () {
        recordBtn.classList.remove('is-loading');
        recordBtn.disabled = false;
        return startRecording();
      }).then(function () {
        recordUI();
        setStatus('Listening… speak now', 'is-live');
        busy = false;
      }).catch(function (e) {
        recordBtn.classList.remove('is-loading');
        recordBtn.disabled = false;
        stopUI();
        // If asr loaded, this is a mic problem. If it didn't, ensureASR already
        // showed the "not installed / couldn't load" note — don't overwrite it.
        if (asr) setStatus(micErrorMessage(e), 'is-error');
        teardownAudio();
        busy = false;
      });
    });
  }

  // ---------------------------------------------------------------------------
  // Voice ribbon (canvas) — idles calmly, swells with the voice while recording
  // ---------------------------------------------------------------------------
  var ctx2d = canvas.getContext('2d');
  var W = 0, H = 0, dpr = 1, ribbonGrad = null;
  var currentAmp = 0, rafId = null, t0 = 0;

  function sizeCanvas() {
    var rect = canvas.getBoundingClientRect();
    dpr = Math.min(window.devicePixelRatio || 1, 2);
    W = Math.max(1, Math.round(rect.width));
    H = Math.max(1, Math.round(rect.height));
    canvas.width = Math.round(W * dpr);
    canvas.height = Math.round(H * dpr);
    ctx2d.setTransform(dpr, 0, 0, dpr, 0, 0);
    ribbonGrad = ctx2d.createLinearGradient(0, 0, W, 0);
    ribbonGrad.addColorStop(0, '#6D8BFF');
    ribbonGrad.addColorStop(0.52, '#A56BFF');
    ribbonGrad.addColorStop(1, '#59D6C6');
  }

  function micAmplitude() {
    if (!analyser) return 0;
    var buf = new Uint8Array(analyser.fftSize);
    analyser.getByteTimeDomainData(buf);
    var sum = 0;
    for (var i = 0; i < buf.length; i++) { var v = (buf[i] - 128) / 128; sum += v * v; }
    return Math.min(1, Math.sqrt(sum / buf.length) * 3.4);
  }

  var LAYERS = [
    { amp: 0.52, freq: 1.1, speed: 0.55, width: 2.6, alpha: 0.95, off: 0.0 },
    { amp: 0.80, freq: 1.7, speed: -0.85, width: 1.8, alpha: 0.5, off: 1.3 },
    { amp: 1.10, freq: 2.5, speed: 1.25, width: 1.2, alpha: 0.3, off: 2.6 }
  ];

  function drawRibbon(t, amp) {
    if (!W || !H) return;
    ctx2d.clearRect(0, 0, W, H);
    var mid = H * 0.5;
    var idle = 0.05, react = 0.34;
    ctx2d.lineCap = 'round';
    ctx2d.lineJoin = 'round';
    ctx2d.strokeStyle = ribbonGrad;
    var step = Math.max(2, Math.floor(W / 140));
    for (var l = 0; l < LAYERS.length; l++) {
      var L = LAYERS[l];
      var A = (idle + amp * react) * L.amp * H;
      ctx2d.beginPath();
      for (var x = 0; x <= W; x += step) {
        var px = x / W;
        var env = Math.sin(Math.PI * px); // taper toward the edges
        var y = mid + Math.sin(px * Math.PI * 2 * L.freq + t * L.speed * Math.PI + L.off) * A * env;
        if (x === 0) ctx2d.moveTo(x, y); else ctx2d.lineTo(x, y);
      }
      ctx2d.globalAlpha = L.alpha;
      ctx2d.lineWidth = L.width;
      ctx2d.stroke();
    }
    ctx2d.globalAlpha = 1;
  }

  function frame(now) {
    var t = (now - t0) / 1000;
    var target = recording ? micAmplitude() : 0;
    currentAmp += (target - currentAmp) * 0.12;
    drawRibbon(t, currentAmp);
    rafId = window.requestAnimationFrame(frame);
  }

  function startRibbon() {
    sizeCanvas();
    if (reduceMotion) { drawRibbon(0, 0); return; } // static, respects the preference
    if (rafId == null) { t0 = window.performance ? performance.now() : Date.now(); rafId = window.requestAnimationFrame(frame); }
  }
  function stopRibbonLoop() { if (rafId != null) { window.cancelAnimationFrame(rafId); rafId = null; } }

  // ---------------------------------------------------------------------------
  // Wiring + init
  // ---------------------------------------------------------------------------
  recordBtn.addEventListener('click', onRecordClick);

  if (copyBtn) {
    copyBtn.addEventListener('click', function () {
      if (!dictated) return;
      var done = function () {
        var prev = copyBtn.textContent;
        copyBtn.textContent = 'Copied';
        setTimeout(function () { copyBtn.textContent = prev || 'Copy'; }, 1400);
      };
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(dictated).then(done).catch(fallbackCopy);
      } else { fallbackCopy(); }
      function fallbackCopy() {
        try {
          var ta = document.createElement('textarea');
          ta.value = dictated;
          ta.setAttribute('readonly', '');
          ta.style.position = 'absolute';
          ta.style.left = '-9999px';
          document.body.appendChild(ta);
          ta.select();
          document.execCommand('copy');
          ta.remove();
          done();
        } catch (e) { /* clipboard unavailable */ }
      }
    });
  }

  if (heroDemoBtn) {
    heroDemoBtn.addEventListener('click', function () {
      var demo = document.getElementById('demo');
      if (demo) demo.scrollIntoView({ behavior: reduceMotion ? 'auto' : 'smooth', block: 'center' });
      setTimeout(function () { if (!recording && !busy) onRecordClick(); }, reduceMotion ? 0 : 480);
    });
  }

  // Resize handling
  if ('ResizeObserver' in window) {
    var ro = new ResizeObserver(function () { sizeCanvas(); if (reduceMotion) drawRibbon(0, 0); });
    ro.observe(canvas);
  } else {
    window.addEventListener('resize', function () { sizeCanvas(); if (reduceMotion) drawRibbon(0, 0); });
  }

  // Pause the animation loop while the tab is hidden (battery friendly)
  document.addEventListener('visibilitychange', function () {
    if (reduceMotion) return;
    if (document.hidden) stopRibbonLoop();
    else if (rafId == null) { t0 = window.performance ? performance.now() : Date.now(); rafId = window.requestAnimationFrame(frame); }
  });

  renderTranscript();
  startRibbon();

  // Proactively let people know if setup hasn't been run yet.
  (window.requestIdleCallback || function (fn) { setTimeout(fn, 400); })(function () {
    probeAssets().then(function (ready) {
      if (!ready) { showNote(NOT_INSTALLED); setStatus('Model not installed yet.'); }
    });
  });

  // Minimal, network-free public hook (handy for debugging; no agent/backend).
  window.VoiceFlow = {
    getTranscript: function () { return dictated; },
    isRecording: function () { return recording; }
  };
})();
