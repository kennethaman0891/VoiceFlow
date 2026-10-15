# VoiceFlow Embed Widget — Fixes Summary

## Issues Fixed

### 1. Path Resolution Broken on Cross-Origin Embeds ✓
**Problem**: `new URL('../', document.currentScript.src)` fails when script is loaded cross-origin (CORS blocks access to `currentScript.src`).

**Solution**: 
- Added `VOICEFLOW_CONFIG.assetsUrl` and `baseUrl` for explicit absolute asset URLs
- Priority: `assetsUrl` > `baseUrl` > same-origin relative paths > graceful failure
- Works with CDN-hosted assets (`https://cdn.example.com/voiceflow/`)
- Graceful degradation with clear error messages when no base URL available

```javascript
// Cross-origin embed configuration
window.VOICEFLOW_CONFIG = {
  assetsUrl: "https://cdn.example.com/voiceflow/",
  allowedOrigins: ["https://your-site.com", "https://another-site.com"]
};
```

### 2. No Iframe Sandboxing ✓
**Problem**: Widget couldn't be loaded in sandboxed iframes; microphone/clipboard permissions missing.

**Solution**:
- Added `allowedOrigins` configuration for postMessage origin validation
- Widget detects iframe context (`window !== window.parent`)
- Parent communication via `postMessage` with origin verification
- Documented required iframe sandbox attributes:
  ```html
  <iframe 
    src="https://cdn.example.com/voiceflow/embed.html"
    allow="microphone; clipboard-write; clipboard-read"
    sandbox="allow-scripts allow-same-origin allow-forms"
  ></iframe>
  ```

### 3. Missing Origin Validation ✓
**Problem**: No validation that widget is loaded from expected origins.

**Solution**:
- `validateEmbedOrigin()` checks script origin vs parent origin
- `isAllowedOrigin()` validates against `allowedOrigins` allowlist
- Supports exact origins, wildcards (`*`), and RegExp patterns
- Graceful fallback: continues working with limited features, warns in debug mode
- postMessage handler only processes messages from allowed origins

### 4. CSP Enforcement ✓
**Problem**: Style injection via `style.textContent` may violate strict CSP (`strict-dynamic`, nonce-based).

**Solution**:
- Added `VOICEFLOW_CONFIG.nonce` for CSP nonce support
- `injectStyles(css, nonce)` applies nonce to injected `<style>` element
- No inline scripts or event handlers (all via `addEventListener`)
- All dynamic content via `textContent` (never `innerHTML` with user data)
- Compatible with `script-src 'nonce-x' 'strict-dynamic'`

### 5. Asset Loading Failures — Poor UX ✓
**Problem**: Generic "not installed" message without actionable guidance.

**Solution**:
- `buildNotInstalledMessage()` generates context-aware error HTML
- Shows exact expected asset paths when `assetsUrl`/`baseUrl` configured
- Provides copy-paste configuration examples
- Links to `setup-offline-stt.sh` for local development
- Distinguishes between "no config" and "assets not at configured URL"

### 6. Color Scheme Inconsistency ✓
**Problem**: Widget used purple-teal gradient (#6D8BFF, #A56BFF, #59D6C6) vs website blue (#3B82F6, #1E3A8A, #7DD3FC).

**Solution**: 
- All gradients updated to website blue theme:
  - `--vf-flow: linear-gradient(100deg, #3B82F6 0%, #1E3A8A 52%, #7DD3FC 100%)`
  - `--vf-live: #7DD3FC` (accent cyan)
  - Recording pulse uses `--vf-live` instead of teal
  - Ribbon canvas gradient matches website exactly
  - Note border-left uses `#3B82F6` (was `#7C86FF`)

### 7. Touch/Mobile Support ✓
**Problem**: Fixed 328px panel overflowed on small screens; no bottom-sheet behavior.

**Solution**:
- Configurable `mobileBreakpoint` (default 480px) and `panelMaxWidth` (`calc(100vw - 24px)`)
- Below breakpoint: bottom-sheet mode with slide-up animation
  - Launch button becomes full-width bar (64px tall)
  - Panel fixed to bottom, full width, max-height `calc(100vh - 64px)`
  - Border radius only on top corners (20px)
  - `overflow-y: auto` for long transcripts
  - Body scroll locked when panel open
- Touch-friendly: `@media (pointer: coarse)` increases button min-height to 48px
- ResizeObserver for canvas resizing
- Reduced motion respected for animations

### 8. postMessage Security ✓
**Problem**: No origin validation for cross-origin communication.

**Solution**:
- `handleMessage(event)` validates `event.origin` against `allowedOrigins`
- Supported actions: `open`, `close`, `startDictation`, `stopDictation`, `getTranscript`, `clearTranscript`
- Parent notified on ready: `postMessage({ type: 'voiceflow', action: 'ready' }, '*')` (only when validated)
- All responses sent to `event.origin` (not `*`)

---

## New Configuration Options

```javascript
window.VOICEFLOW_CONFIG = {
  // Existing options
  position: "bottom-right",        // "bottom-right" | "bottom-left"
  title: "Dictate",
  subtitle: "Speak — it types, on your device",
  theme: "auto",                   // "auto" | "dark" | "light"
  
  // NEW: Cross-origin asset resolution
  baseUrl: "",                     // Absolute base URL (legacy, use assetsUrl)
  assetsUrl: "",                   // Explicit assets URL for CDN hosting
  
  // NEW: Security
  allowedOrigins: [],              // Allowlist for postMessage (origins, "*", or RegExp)
  nonce: "",                       // CSP nonce for style injection
  
  // NEW: Mobile responsiveness
  mobileBreakpoint: 480,           // Viewport width for bottom-sheet mode
  panelWidth: 328,                 // Desktop panel width (px)
  panelMaxWidth: "calc(100vw - 24px)", // Max panel width (CSS)
  
  // NEW: Debugging
  debug: false                     // Enable console logging
};
```

---

## Test Scenarios Covered

| Scenario | Status | Notes |
|----------|--------|-------|
| Same-origin embed (current) | ✓ | Works as before, relative paths |
| Cross-origin embed from different domain | ✓ | Requires `assetsUrl` config |
| Iframe embed with sandbox | ✓ | Requires `allow="microphone; clipboard-write"` |
| Mobile viewport (320px, 375px, 428px) | ✓ | Bottom-sheet mode activates ≤480px |
| Desktop viewport | ✓ | 328px panel, bottom-right anchored |
| With model assets installed | ✓ | Full functionality |
| Without model assets | ✓ | Clear setup instructions shown |
| CSP strict-dynamic + nonce | ✓ | `nonce` config option |
| High contrast mode | ✓ | `@media (prefers-contrast: more)` |
| Reduced motion | ✓ | `@media (prefers-reduced-motion: reduce)` |

---

## Migration Guide

### For Existing Same-Origin Users
No changes required. Widget auto-detects same-origin and uses relative paths.

### For Cross-Origin Embeds
```html
<!-- Before (broken) -->
<script src="https://cdn.example.com/embed/voiceflow-embed.js" defer></script>

<!-- After (fixed) -->
<script>
window.VOICEFLOW_CONFIG = {
  assetsUrl: "https://cdn.example.com/voiceflow/",
  allowedOrigins: ["https://your-site.com"]
};
</script>
<script src="https://cdn.example.com/embed/voiceflow-embed.js" defer></script>
```

### For Iframe Embeds
```html
<!-- Parent page -->
<script>
window.VOICEFLOW_CONFIG = {
  assetsUrl: "https://cdn.example.com/voiceflow/",
  allowedOrigins: ["https://parent-site.com"]
};
</script>

<iframe 
  src="https://cdn.example.com/voiceflow/embed-frame.html"
  allow="microphone; clipboard-write; clipboard-read"
  sandbox="allow-scripts allow-same-origin allow-forms"
  style="width:100%; height:400px; border:none; border-radius:12px;"
></iframe>
```

### For CSP-Protected Sites
```html
<!-- Generate a random nonce per page load -->
<script>
window.VOICEFLOW_CONFIG = {
  nonce: "RANDOM_NONCE_FROM_SERVER",
  assetsUrl: "https://cdn.example.com/voiceflow/"
};
</script>
<script src="/embed/voiceflow-embed.js" nonce="RANDOM_NONCE_FROM_SERVER" defer></script>

<!-- CSP Header -->
Content-Security-Policy: 
  script-src 'nonce-RANDOM_NONCE_FROM_SERVER' 'strict-dynamic';
  style-src 'nonce-RANDOM_NONCE_FROM_SERVER';
  connect-src 'self' https://cdn.example.com;
  media-src 'self' blob:;
  worker-src 'self' blob:;
```

---

## Files Changed

- `Website/embed/voiceflow-embed.js` — Complete rewrite with all fixes
- `Website/embed/test-embed.html` — Test page demonstrating all scenarios

---

## Backward Compatibility

✅ Fully backward compatible — existing embeds continue working unchanged
✅ New features are opt-in via configuration
✅ No breaking changes to DOM structure or CSS class names
✅ Same global `window.__voiceflowEmbedLoaded` guard
