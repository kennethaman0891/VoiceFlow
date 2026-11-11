import React, { useState, useEffect } from 'react';
import ReactDOM from 'react-dom/client';
import App from './App';
import FloatingHUD from './components/FloatingHUD';
import { listen } from '@tauri-apps/api/event';
import { invoke } from '@tauri-apps/api/core';
import { AppStatus } from './types';

function OverlayApp() {
  const [status, setStatus] = useState<AppStatus>('idle');
  const [liveTranscript, setLiveTranscript] = useState('');
  const [errorMessage, setErrorMessage] = useState('');
  const [showWidget, setShowWidget] = useState(true);

  useEffect(() => {
    const unlistenStatus = listen<AppStatus>('status', (event) => {
      const next = event.payload;
      setStatus(next);
      if (next !== 'error') {
        setErrorMessage('');
      }
      if (next === 'idle') {
        window.setTimeout(() => setLiveTranscript(''), 2000);
      }
    });

    const unlistenTranscript = listen<string>('transcript', (event) => {
      const text = typeof event.payload === 'string' ? event.payload : '';
      if (text) {
        setLiveTranscript(text);
      }
    });

    const unlistenError = listen<string>('error', (event) => {
      const message = typeof event.payload === 'string' ? event.payload : 'Something went wrong';
      setErrorMessage(message);
      setStatus('error');
    });

    const unlistenSettings = listen<any>('settings_changed', (event) => {
      const nextSettings = event.payload;
      if (nextSettings && typeof nextSettings.show_mic_widget === 'boolean') {
        setShowWidget(nextSettings.show_mic_widget);
      }
    });

    invoke('get_settings').then((settings: any) => {
      if (settings) {
        setShowWidget(settings.show_mic_widget ?? true);
      }
    }).catch(console.error);

    return () => {
      unlistenStatus.then((unlisten) => unlisten());
      unlistenTranscript.then((unlisten) => unlisten());
      unlistenError.then((unlisten) => unlisten());
      unlistenSettings.then((unlisten) => unlisten());
    };
  }, []);

  const handleToggleRecording = async () => {
    try {
      await invoke('toggle_recording');
    } catch (error) {
      console.error('Recording failed:', error);
      setErrorMessage(error instanceof Error ? error.message : 'Recording failed');
      setStatus('error');
    }
  };

  const handleCancel = async () => {
    try {
      await invoke('cancel_recording');
    } catch (error) {
      console.error('Cancel recording failed:', error);
    }
  };

  if (!showWidget) return null;

  return (
    <FloatingHUD
      status={status}
      liveTranscript={liveTranscript}
      errorMessage={errorMessage}
      onToggleRecording={handleToggleRecording}
      onCancel={handleCancel}
      visible={true}
    />
  );
}

const isOverlay = window.location.hash === '#overlay';
if (isOverlay) {
  document.body.classList.add('overlay-mode');
}

ReactDOM.createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    {isOverlay ? <OverlayApp /> : <App />}
  </React.StrictMode>,
);
