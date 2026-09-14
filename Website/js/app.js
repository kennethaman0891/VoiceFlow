/**
 * VoiceFlow site shell — copy-to-clipboard for the embed snippet, a small toast,
 * and honest "build from source" guidance for the download buttons.
 * No network calls, no analytics.
 */
(function () {
  'use strict';

  function copy(text) {
    if (navigator.clipboard && navigator.clipboard.writeText) {
      return navigator.clipboard.writeText(text).catch(fallback);
    }
    return Promise.resolve(fallback());
    function fallback() {
      try {
        var ta = document.createElement('textarea');
        ta.value = text;
        ta.setAttribute('readonly', '');
        ta.style.position = 'absolute';
        ta.style.left = '-9999px';
        document.body.appendChild(ta);
        ta.select();
        document.execCommand('copy');
        ta.remove();
      } catch (e) { /* clipboard unavailable */ }
    }
  }

  function toast(msg) {
    var el = document.getElementById('_vf_toast');
    if (!el) {
      el = document.createElement('div');
      el.id = '_vf_toast';
      el.setAttribute('role', 'status');
      el.style.cssText = [
        'position:fixed', 'bottom:24px', 'left:50%', 'transform:translateX(-50%)',
        'background:var(--surface,#141826)', 'color:var(--text,#EEF1FA)',
        'border:1px solid var(--hairline-strong,rgba(255,255,255,.14))',
        'padding:11px 16px', 'border-radius:999px', 'font-size:14px', 'font-weight:600',
        'box-shadow:0 16px 40px rgba(0,0,0,.4)', 'z-index:9999', 'opacity:0',
        'transition:opacity .18s ease', 'pointer-events:none'
      ].join(';');
      document.body.appendChild(el);
    }
    el.textContent = msg;
    el.style.opacity = '1';
    clearTimeout(toast._t);
    toast._t = setTimeout(function () { el.style.opacity = '0'; }, 1700);
  }

  // Copy the embed snippet shown in the Embed section
  var copyCodeBtn = document.getElementById('copyCodeBtn');
  var embedCode = document.getElementById('embedCode');
  if (copyCodeBtn && embedCode) {
    copyCodeBtn.addEventListener('click', function () {
      copy(embedCode.textContent).then(function () {
        toast('Embed snippet copied');
        var prev = copyCodeBtn.textContent;
        copyCodeBtn.textContent = 'Copied';
        setTimeout(function () { copyCodeBtn.textContent = prev || 'Copy'; }, 1500);
      });
    });
  }

  // Download buttons — builds aren't published yet, so point people at the
  // honest path: build from source. No placeholder domains.
  var BUILDS = {
    macos: 'macOS build coming soon.\n\nBuild it from source in the meantime:\n\n' +
           '  git clone <your-repo-url>\n' +
           '  cd VoiceFlow\n' +
           '  xcodegen generate\n' +
           '  xcodebuild -project VoiceFlow.xcodeproj -scheme VoiceFlow build\n\n' +
           'Dictation runs on-device with Whisper.cpp — no cloud speech service.',
    windows: 'Windows build coming soon.\n\nBuild it from source in the meantime:\n\n' +
             '  git clone <your-repo-url>\n' +
             '  cd VoiceFlow/tauri-app\n' +
             '  npm install\n' +
             '  npm run tauri build\n\n' +
             'Dictation runs on-device with Whisper.cpp — no cloud speech service.'
  };

  var downloadBtns = document.querySelectorAll('.btn-download');
  Array.prototype.forEach.call(downloadBtns, function (btn) {
    btn.addEventListener('click', function () {
      var platform = btn.dataset.platform;
      if (BUILDS[platform]) window.alert(BUILDS[platform]);
    });
  });
})();
