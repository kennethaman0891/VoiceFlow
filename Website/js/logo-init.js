// VoiceFlow — logo showcase initializer (extracted from index.html inline script).
// Plain, non-module script loaded with defer AFTER js/three/logo.js (a module).
// Modules execute after the document is parsed, so window.VoiceFlowLogo is set
// before this DOMContentLoaded listener fires — load order is preserved.

// Duplicate the logo instance for the showcase section
document.addEventListener('DOMContentLoaded', () => {
  const container2 = document.getElementById('logo-container-2');
  if (container2 && window.VoiceFlowLogo) {
    window.VoiceFlowLogo.cloneTo(container2);
  }
});
