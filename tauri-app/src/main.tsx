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
  const [shortcut, setShortcut] = useState('Left Option + Space');
  const [notice, setNotice] = useState<string | null>(null);
  const [captureWarning, setCaptureWarning] = useState('');

  useEffect(() => {
    let noticeTimer: number | null = null;
    const showNotice = (kind: string) => {
      setNotice(kind);
      if (noticeTimer) window.clearTimeout(noticeTimer);
      const hold = kind === 'copied' ? 5000 : 4000;
      noticeTimer = window.setTimeout(() => setNotice(null), hold);
    };

    const listenSafe = <T,>(event: string, handler: (event: { payload: T }) => void) =>
      listen<T>(event, handler).catch(() => () => {});

    const unlistenStatus = listenSafe<AppStatus>('status', (event) => {
      const next = event.payload;
      setStatus(next);
      if (next !== 'error') {
        setErrorMessage('');
      }
      if (next === 'recording' || next === 'hands_free' || next === 'transcribing') {
        setNotice(null);
        if (noticeTimer) window.clearTimeout(noticeTimer);
      }
      if (next === 'recording' || next === 'hands_free') {
        setLiveTranscript('');
        setCaptureWarning('');
      }
      if (next === 'idle') {
        setCaptureWarning('');
      }
      if (next === 'idle') {
        window.setTimeout(() => setLiveTranscript(''), 2000);
      }
    });

    const unlistenNotice = listenSafe<{ kind?: string }>('overlay_notice', (event) => {
      const kind = event.payload?.kind;
      if (kind === 'no_sound' || kind === 'copied') showNotice(kind);
    });

    const unlistenTranscript = listenSafe<string>('transcript', (event) => {
      const text = typeof event.payload === 'string' ? event.payload : '';
      if (text) {
        setLiveTranscript(text);
        setCaptureWarning('');
      }
    });

    const unlistenPartial = listenSafe<string>('partial_transcript', (event) => {
      const text = typeof event.payload === 'string' ? event.payload : '';
      if (text) {
        setLiveTranscript(text);
        setCaptureWarning('');
      }
    });

    const unlistenWarning = listenSafe<string>('capture_warning', (event) => {
      setCaptureWarning(typeof event.payload === 'string' ? event.payload : '');
    });

    const unlistenError = listenSafe<string>('error', (event) => {
      const message = typeof event.payload === 'string' ? event.payload : 'Something went wrong';
      setErrorMessage(message);
      setStatus('error');
    });

    const unlistenSettings = listenSafe<any>('settings_changed', (event) => {
      const nextSettings = event.payload;
      if (nextSettings && typeof nextSettings.show_mic_widget === 'boolean') {
        setShowWidget(nextSettings.show_mic_widget);
      }
      if (nextSettings && typeof nextSettings.transcribe_shortcut === 'string') {
        setShortcut(nextSettings.transcribe_shortcut);
      }
    });

    invoke('get_settings').then((settings: any) => {
      if (settings) {
        setShowWidget(settings.show_mic_widget ?? true);
        if (typeof settings.transcribe_shortcut === 'string' && settings.transcribe_shortcut) {
          setShortcut(settings.transcribe_shortcut);
        }
      }
    }).catch(console.error);

    return () => {
      if (noticeTimer) window.clearTimeout(noticeTimer);
      for (const unlisten of [unlistenStatus, unlistenNotice, unlistenTranscript, unlistenPartial, unlistenWarning, unlistenError, unlistenSettings]) {
        unlisten.then((fn) => fn()).catch(() => {});
      }
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

  const handleOpen = async () => {
    try {
      await invoke('show_main_window');
    } catch (error) {
      console.error('Open window failed:', error);
    }
  };

  if (!showWidget) return null;

  return (
    <FloatingHUD
      status={status}
      liveTranscript={liveTranscript}
      errorMessage={errorMessage}
      shortcut={shortcut}
      notice={notice}
      captureWarning={captureWarning}
      onToggleRecording={handleToggleRecording}
      onCancel={handleCancel}
      onOpen={handleOpen}
      visible={true}
    />
  );
}

const isPreview = window.location.hash === '#hud-preview';
const isOverlay = window.location.hash === '#overlay' || isPreview;
if (window.location.hash === '#overlay') {
  document.body.classList.add('overlay-mode');
}
if (isPreview) {
  document.body.classList.add('hud-preview');
}

function HudPreview() {
  const samples: Array<{ label: string; status: AppStatus; text?: string; error?: string; notice?: string }> = [
    { label: 'idle', status: 'idle' },
    { label: 'arming', status: 'recording', text: '' },
    { label: 'transcribing', status: 'transcribing', text: 'The quick brown fox jumps over the lazy dog and keeps talking.' },
    { label: 'pasted', status: 'success', text: 'The note is ready.' },
    { label: 'no sound', status: 'idle', notice: 'no_sound' },
    { label: 'error', status: 'error', error: 'Microphone unavailable' },
  ];
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 18, padding: 24, background: '#1c2430', minHeight: '100%' }}>
      {samples.map((sample) => (
        <div key={sample.label} style={{ height: 168 }}>
          <FloatingHUD
            status={sample.status}
            liveTranscript={sample.text}
            errorMessage={sample.error}
            notice={sample.notice}
            shortcut="Left Option + Space"
            onToggleRecording={() => {}}
            onCancel={() => {}}
          />
        </div>
      ))}
    </div>
  );
}

ReactDOM.createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    {isPreview ? <HudPreview /> : isOverlay ? <OverlayApp /> : <App />}
  </React.StrictMode>,
);
