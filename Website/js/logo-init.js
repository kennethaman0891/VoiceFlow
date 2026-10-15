// VoiceFlow — logo showcase initializer (extracted from index.html inline script).
// Plain, non-module script loaded with defer AFTER js/three/logo.js (a module).
// Modules execute after the document is parsed, so window.VoiceFlowLogo is set
// before this DOMContentLoaded listener fires — load order is preserved.

// Duplicate the logo instance for the showcase section
document.addEventListener('DOMContentLoaded', async () => {
  const container2 = document.getElementById('logo-container-2');
  if (container2 && window.VoiceFlowLogo && window.VoiceFlowLogo.cloneTo) {
    try {
      await window.VoiceFlowLogo.cloneTo(container2);
    } catch (e) {
      console.warn('VoiceFlow logo clone failed:', e);
    }
  }
});

// Handle resize events for all 3D logos
window.addEventListener('resize', () => {
  if (window.VoiceFlowLogo && window.VoiceFlowLogo.resizeAll) {
    window.VoiceFlowLogo.resizeAll();
  }
});

// Handle orientation change
window.addEventListener('orientationchange', () => {
  setTimeout(() => {
    if (window.VoiceFlowLogo && window.VoiceFlowLogo.resizeAll) {
      window.VoiceFlowLogo.resizeAll();
    }
  }, 300);
});