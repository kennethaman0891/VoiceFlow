import { useState, useEffect } from 'react';
import { invoke } from '@tauri-apps/api/core';
import { listen } from '@tauri-apps/api/event';
import MenuBar from './components/MenuBar';
import RecordingOverlay from './components/RecordingOverlay';
import TranscriptView from './components/TranscriptView';
import SettingsPanel from './components/SettingsPanel';
import Onboarding from './components/Onboarding';

interface AppState {
  status: 'idle' | 'recording' | 'transcribing' | 'cleaning' | 'error';
  transcript: string[];
  settings: {
    language: string;
    autoPaste: boolean;
    whisperModel: string;
    cleanupModel: string;
    showMicWidget?: boolean;
  };
  models: Array<{ name: string; filename: string; downloaded: boolean; sizeMb: number; url: string }>;
  isDownloading: Record<string, boolean>;
}

export default function App() {
  const [state, setState] = useState<AppState>({
    status: 'idle',
    transcript: [],
    settings: {
      language: 'en',
      autoPaste: true,
      whisperModel: 'medium',
      cleanupModel: 'off',
      showMicWidget: true, // Show mic widget by default
    },
    models: [],
    isDownloading: {},
  });
  const [showSettings, setShowSettings] = useState(false);
  const [modelsReady, setModelsReady] = useState(false);

  useEffect(() => {
    // Check model availability on startup
    loadModels();

    // Load saved settings
    invoke('get_settings').then((settings: any) => {
      if (settings) {
        setState(prev => ({
          ...prev,
          settings: {
            language: settings.language || 'en',
            autoPaste: settings.auto_paste ?? true,
            whisperModel: settings.whisper_model || 'medium',
            cleanupModel: settings.cleanup_model || 'off',
            showMicWidget: settings.show_mic_widget ?? true,
          },
        }));
      }
    }).catch(console.error);

    // Listen for status changes from backend
    const unlistenStatus = listen('status', (event: any) => {
      const newStatus = event.payload as 'idle' | 'recording' | 'transcribing' | 'cleaning' | 'error';
      setState(prev => ({ ...prev, status: newStatus }));
    });

    // Listen for transcript events
    const unlistenTranscript = listen('transcript', (event: any) => {
      const text = event.payload as string;
      if (text?.trim()) {
        setState(prev => ({
          ...prev,
          transcript: [...prev.transcript, text],
        }));
      }
    });

    // Listen for error events
    const unlistenError = listen('error', (event: any) => {
      const message = event.payload as string;
      console.error('Backend error:', message);
      setState(prev => ({ ...prev, status: 'error' }));
    });

    // Listen for hotkey press events from backend
    const unlistenHotkey = listen('hotkey_press', () => {
      // Handle hotkey press - start recording if idle
      if (state.status === 'idle') {
        handleToggleRecording();
      }
    });

    // Cleanup listeners
    return () => {
      unlistenStatus.then(unlisten => unlisten());
      unlistenTranscript.then(unlisten => unlisten());
      unlistenError.then(unlisten => unlisten());
      unlistenHotkey.then(unlisten => unlisten());
    };
  }, [state.status]);

  const loadModels = async () => {
    try {
      const models: any[] = await invoke('get_models');
      setState(prev => ({ ...prev, models }));

      // Check if core models are available
      const hasWhisper = models.some(m => m.downloaded && m.filename.includes('ggml'));
      const hasAtLeastOne = models.length > 0;
      setModelsReady(hasWhisper || hasAtLeastOne);
    } catch (error) {
      console.error('Failed to load models:', error);
    }
  };

  const handleDownload = async (url: string, filename: string, sizeMb: number) => {
    setState(prev => ({
      ...prev,
      isDownloading: { ...prev.isDownloading, [filename]: true },
    }));

    try {
      await invoke('download_model', { url, filename });
      setState(prev => ({
        ...prev,
        isDownloading: { ...prev.isDownloading, [filename]: false },
      }));
      await loadModels();
    } catch (error) {
      console.error('Download failed:', error);
      setState(prev => ({
        ...prev,
        isDownloading: { ...prev.isDownloading, [filename]: false },
      }));
    }
  };

  const handleToggleRecording = async () => {
    try {
      await invoke('toggle_recording');
    } catch (error) {
      console.error('Recording failed:', error);
      setState(prev => ({ ...prev, status: 'error' }));
    }
  };

  const handleUpdateSettings = async (newSettings: typeof state.settings) => {
    await invoke('update_settings', {
      settings: {
        language: newSettings.language,
        auto_paste: newSettings.autoPaste,
        whisper_model: newSettings.whisperModel,
        cleanup_model: newSettings.cleanupModel,
        show_mic_widget: newSettings.showMicWidget,
      },
    });
    setState(prev => ({ ...prev, settings: newSettings }));
    setShowSettings(false);
  };

  return (
    <div className="app">
      <MenuBar
        onToggleSettings={() => setShowSettings(!showSettings)}
        status={state.status}
      />



      <main className="main">
        <RecordingOverlay status={state.status} />
        <TranscriptView
          transcript={state.transcript}
          onAddTranscript={(text) => {
            setState(prev => ({
              ...prev,
              transcript: [...prev.transcript, text],
            }));
          }}
        />
      </main>

      {showSettings && (
        <SettingsPanel
          settings={state.settings}
          models={state.models}
          isDownloading={state.isDownloading}
          onSave={handleUpdateSettings}
          onClose={() => setShowSettings(false)}
          onDownload={handleDownload}
        />
      )}

      {/* Floating record button */}
      <button
        className={`record-fab ${state.status === 'recording' ? 'recording' : ''}`}
        onClick={handleToggleRecording}
        aria-label={state.status === 'recording' ? 'Stop recording' : 'Start recording'}
        title={state.status === 'recording' ? 'Stop (Space)' : 'Start (Space)'}
      >
        <svg viewBox="0 0 24 24" width="28" height="28" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
          <path d="M12 1a3 3 0 0 0-3 3v8a3 3 0 0 0 6 0V4a3 3 0 0 0-3-3z"/>
          <path d="M19 10a7 7 0 0 1-14 0"/>
          <line x1="12" y1="19" x2="12" y2="23"/>
          <line x1="8" y1="23" x2="16" y2="23"/>
        </svg>
      </button>

      {!modelsReady && !showSettings && (
        <Onboarding
          models={state.models}
          onDownload={handleDownload}
          onComplete={() => setModelsReady(true)}
        />
      )}
    </div>
  );
}