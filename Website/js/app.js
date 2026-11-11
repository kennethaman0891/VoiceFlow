(function () {
  'use strict';

  // Mobile nav toggle
  var navToggle = document.getElementById('navToggle');
  var navMobileMenu = document.getElementById('navMobileMenu');
  if (navToggle && navMobileMenu) {
    var closeMenu = function () {
      navToggle.setAttribute('aria-expanded', 'false');
      navMobileMenu.classList.remove('is-open');
      document.body.style.overflow = '';
    };

    var openMenu = function () {
      navToggle.setAttribute('aria-expanded', 'true');
      navMobileMenu.classList.add('is-open');
      document.body.style.overflow = 'hidden';
    };

    navToggle.addEventListener('click', function () {
      var isOpen = navToggle.getAttribute('aria-expanded') === 'true';
      if (isOpen) { closeMenu(); } else { openMenu(); }
    });

    // Close menu when a link is clicked
    var mobileLinks = navMobileMenu.querySelectorAll('a');
    Array.prototype.forEach.call(mobileLinks, function (link) {
      link.addEventListener('click', closeMenu);
    });

    // Close menu when clicking outside
    document.addEventListener('click', function (e) {
      if (!navToggle.contains(e.target) && !navMobileMenu.contains(e.target)) {
        closeMenu();
      }
    });

    // Close menu on Escape key
    document.addEventListener('keydown', function (e) {
      if (e.key === 'Escape' && navMobileMenu.classList.contains('is-open')) {
        closeMenu();
        navToggle.focus();
      }
    });

    // Handle resize - close menu if viewport becomes wide enough for desktop nav
    var resizeTimer = null;
    window.addEventListener('resize', function () {
      clearTimeout(resizeTimer);
      resizeTimer = setTimeout(function () {
        if (window.innerWidth > 760 && navMobileMenu.classList.contains('is-open')) {
          closeMenu();
        }
      }, 150);
    });
  }

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

  // Ensure 3D logo canvases resize properly on container changes
  function handle3DCanvasResize() {
    // Trigger resize on all Three.js canvases
    var canvases = document.querySelectorAll('.hero-logo-wrap canvas, .mic-3d-wrap canvas');
    canvases.forEach(function (canvas) {
      if (!canvas._threeRenderer || !canvas.parentElement) return;
      // Hero sizing lives in logo.js so the camera aspect stays in sync.
      if (canvas.parentElement.classList.contains('hero-stage')) return;
      var rect = canvas.parentElement.getBoundingClientRect();
      var size = Math.min(rect.width, rect.height) || 400;
      canvas._threeRenderer.setSize(size, size);
    });
  }

  // Expose for debugging
  window.VoiceFlowApp = {
    handle3DCanvasResize: handle3DCanvasResize
  };

  // Run initial resize check after DOM is ready
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', handle3DCanvasResize);
  } else {
    handle3DCanvasResize();
  }

  // Also check on orientation change
  window.addEventListener('orientationchange', function () {
    setTimeout(handle3DCanvasResize, 300);
  });
})();