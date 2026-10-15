import React from 'react';
import ReactDOM from 'react-dom/client';
import App from './App';
import MicWidget from './components/MicWidget';
import { useState, useEffect } from 'react';
import { listen } from '@tauri-apps/api/event';
import { invoke } from '@tauri-apps/api/core';

// Lightweight overlay app - only renders the floating mic widget
function OverlayApp() {
  const [status, setStatus] = useState<'idle' | 'recording' | 'transcribing' | 'cleaning' | 'error'>('idle');
  const [showWidget, setShowWidget] = useState(true);

  useEffect(() => {
    // Listen for status changes from backend
    const unlistenStatus = listen('status', (event: any) => {
      const newStatus = event.payload as 'idle' | 'recording' | 'transcribing' | 'cleaning' | 'error';
      setStatus(newStatus);
    });

    // Listen for hotkey press
    const unlistenHotkey = listen('hotkey_press', () => {
      if (status === 'idle') {
        handleToggleRecording();
      }
    });

    // Load settings to check if widget should be shown
    invoke('get_settings').then((settings: any) => {
      if (settings) {
        setShowWidget(settings.show_mic_widget ?? true);
      }
    }).catch(console.error);

    return () => {
      unlistenStatus.then(unlisten => unlisten());
      unlistenHotkey.then(unlisten => unlisten());
    };
  }, [status]);

  const handleToggleRecording = async () => {
    try {
      await invoke('toggle_recording');
    } catch (error) {
      console.error('Recording failed:', error);
      setStatus('error');
    }
  };

  if (!showWidget) return null;

  return (
    <MicWidget
      status={status}
      onToggleRecording={handleToggleRecording}
      visible={true}
    />
  );
}

// Detect if we're in the overlay window
const isOverlay = window.location.hash === '#overlay';
console.log('[VoiceFlow] Window detection:', { 
  hash: window.location.hash, 
  isOverlay, 
  href: window.location.href,
  userAgent: navigator.userAgent
});

ReactDOM.createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    {isOverlay ? <OverlayApp /> : <App />}
  </React.StrictMode>,
);
