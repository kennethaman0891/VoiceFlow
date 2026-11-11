import React, { useState, useEffect } from 'react';
import { invoke } from '@tauri-apps/api/core';
import { listen } from '@tauri-apps/api/event';
import TitleBar from './TitleBar';
import Sidebar, { DesktopTab } from './Sidebar';
import StatusBar from './StatusBar';
import GeneralView from './GeneralView';
import ModelsView from './ModelsView';
import AdvancedView from './AdvancedView';
import HistoryView from './HistoryView';
import AboutView from './AboutView';
import { AppStatus, HardwareProfile, ListedModel } from '../../types';
import './DesktopUI.css';

interface DesktopSettingsState {
  language: string;
  autoPaste: boolean;
  whisperModel: string;
  cleanupModel: string;
  showMicWidget: boolean;
  silenceTimeoutMs: number;
  doubleClickEnabled: boolean;
  transcribeShortcut: string;
  pushToTalk: boolean;
  microphone: string;
  muteWhileRecording: boolean;
  audioFeedback: boolean;
  outputDevice: string;
  feedbackVolume: number;
}

export default function DesktopApp() {
  const [activeTab, setActiveTab] = useState<DesktopTab>('general');
  const [status, setStatus] = useState<AppStatus>('idle');
  const [transcript, setTranscript] = useState<string[]>([]);
  const [hardware, setHardware] = useState<HardwareProfile | null>(null);
  const [models, setModels] = useState<ListedModel[]>([]);
  const [isDownloading, setIsDownloading] = useState<Record<string, boolean>>({});
  const [availableMicrophones, setAvailableMicrophones] = useState<string[]>([]);

  const [settings, setSettings] = useState<DesktopSettingsState>({
    language: 'en',
    autoPaste: true,
    whisperModel: 'base',
    cleanupModel: 'off',
    showMicWidget: true,
    silenceTimeoutMs: 2000,
    doubleClickEnabled: true,
    transcribeShortcut: 'Left Option + Space',
    pushToTalk: true,
    microphone: 'MacBook Pro Microphone',
    muteWhileRecording: false,
    audioFeedback: false,
    outputDevice: 'Default',
    feedbackVolume: 100,
  });

  useEffect(() => {
    // 1. Fetch saved settings
    invoke('get_settings')
      .then((saved: any) => {
        if (saved) {
          setSettings((prev) => ({
            ...prev,
            language: saved.language || prev.language,
            autoPaste: saved.auto_paste ?? prev.autoPaste,
            whisperModel: saved.whisper_model || prev.whisperModel,
            cleanupModel: saved.cleanup_model || prev.cleanupModel,
            showMicWidget: saved.show_mic_widget ?? prev.showMicWidget,
            silenceTimeoutMs: saved.silence_timeout_ms ?? prev.silenceTimeoutMs,
            doubleClickEnabled: saved.double_click_enabled ?? prev.doubleClickEnabled,
            transcribeShortcut: saved.transcribe_shortcut || prev.transcribeShortcut,
            pushToTalk: saved.push_to_talk ?? prev.pushToTalk,
            microphone: saved.microphone || prev.microphone,
            muteWhileRecording: saved.mute_while_recording ?? prev.muteWhileRecording,
            audioFeedback: saved.audio_feedback ?? prev.audioFeedback,
            outputDevice: saved.output_device || prev.outputDevice,
            feedbackVolume: saved.feedback_volume ?? prev.feedbackVolume,
          }));
        }
      })
      .catch(console.error);

    // 2. Fetch available microphones
    invoke<string[]>('list_microphones')
      .then((mics) => {
        if (mics && mics.length > 0) {
          setAvailableMicrophones(mics);
        }
      })
      .catch(console.error);

    // 3. Profile Hardware
    invoke<HardwareProfile>('profile_hardware')
      .then((hw) => setHardware(hw))
      .catch(console.error);

    // 4. Fetch Models
    loadModels();

    // 5. Backend event listeners
    const unlistenStatus = listen('status', (event: any) => {
      setStatus(event.payload as AppStatus);
    });

    const unlistenTranscript = listen('transcript', (event: any) => {
      const text = event.payload as string;
      if (text && text.trim()) {
        setTranscript((prev) => [text, ...prev]);
      }
    });

    return () => {
      unlistenStatus.then((fn) => fn());
      unlistenTranscript.then((fn) => fn());
    };
  }, []);

  const loadModels = async () => {
    try {
      const raw = await invoke<Array<{
        name: string;
        filename: string;
        downloaded: boolean;
        size_mb?: number;
        sizeMb?: number;
        url: string;
        sha256?: string;
      }>>('get_models');

      const mapped: ListedModel[] = raw.map((m) => ({
        name: m.name,
        filename: m.filename,
        downloaded: !!m.downloaded,
        sizeMb: Number(m.size_mb ?? m.sizeMb ?? 0),
        url: m.url || '',
        sha256: m.sha256,
      }));

      setModels(mapped);
    } catch (e) {
      console.error('Failed to load models:', e);
    }
  };

  const persistSettings = async (nextSettings: DesktopSettingsState) => {
    setSettings(nextSettings);
    try {
      await invoke('update_settings', {
        settings: {
          language: nextSettings.language,
          auto_paste: nextSettings.autoPaste,
          show_mic_widget: nextSettings.showMicWidget,
          output_device: nextSettings.outputDevice === 'Default' ? null : nextSettings.outputDevice,
          whisper_model: nextSettings.whisperModel,
          cleanup_model: nextSettings.cleanupModel,
          silence_timeout_ms: nextSettings.silenceTimeoutMs,
          double_click_enabled: nextSettings.doubleClickEnabled,
          transcribe_shortcut: nextSettings.transcribeShortcut,
          push_to_talk: nextSettings.pushToTalk,
          microphone: nextSettings.microphone,
          mute_while_recording: nextSettings.muteWhileRecording,
          audio_feedback: nextSettings.audioFeedback,
          feedback_volume: nextSettings.feedbackVolume,
        },
      });
    } catch (e) {
      console.error('Failed to update settings:', e);
    }
  };

  const handleSettingChange = (key: string, value: any) => {
    const next = { ...settings, [key]: value };
    persistSettings(next);
  };

  const handleResetKey = (key: string) => {
    const defaults: Record<string, any> = {
      transcribeShortcut: 'Left Option + Space',
      language: 'en',
      microphone: availableMicrophones[0] || 'MacBook Pro Microphone',
      outputDevice: 'Default',
    };
    if (defaults[key] !== undefined) {
      handleSettingChange(key, defaults[key]);
    }
  };

  const handleSelectModel = (modelId: string) => {
    handleSettingChange('whisperModel', modelId);
  };

  const handleDownloadModel = async (
    url: string,
    filename: string,
    _sizeMb: number,
    sha256?: string
  ) => {
    setIsDownloading((prev) => ({ ...prev, [filename]: true }));
    try {
      await invoke('download_model', {
        url,
        filename,
        expectedSha256: sha256 ?? null,
      });
      await loadModels();
    } catch (e) {
      console.error('Model download failed:', e);
    } finally {
      setIsDownloading((prev) => ({ ...prev, [filename]: false }));
    }
  };

  const handleApplyRecommended = () => {
    if (!hardware) return;
    const recId = hardware.recommended_model_id || 'base';
    handleSettingChange('whisperModel', recId);
  };

  return (
    <div className="desktop-shell">
      {/* 1. Frameless macOS-style Titlebar */}
      <TitleBar />

      {/* 2. Main Body with Fixed Sidebar and Dynamic Content Area */}
      <div className="desktop-body">
        <Sidebar activeTab={activeTab} onSelectTab={setActiveTab} />

        <main className="desktop-content">
          {activeTab === 'general' && (
            <GeneralView
              settings={settings}
              availableMicrophones={availableMicrophones}
              onChange={handleSettingChange}
              onResetKey={handleResetKey}
            />
          )}

          {activeTab === 'models' && (
            <ModelsView
              currentModel={settings.whisperModel}
              hardware={hardware}
              models={models}
              isDownloading={isDownloading}
              onSelectModel={handleSelectModel}
              onDownloadModel={handleDownloadModel}
              onApplyRecommended={handleApplyRecommended}
            />
          )}

          {activeTab === 'advanced' && (
            <AdvancedView
              settings={settings}
              onChange={handleSettingChange}
              onResetKey={handleResetKey}
            />
          )}

          {activeTab === 'history' && (
            <HistoryView
              transcript={transcript}
              onClearHistory={() => setTranscript([])}
            />
          )}

          {activeTab === 'about' && <AboutView hardware={hardware} />}
        </main>
      </div>

      {/* 3. Persistent Status Bar at Bottom */}
      <StatusBar
        status={status}
        activeModel={settings.whisperModel}
        models={models}
        onSelectModel={handleSelectModel}
        onOpenModelsTab={() => setActiveTab('models')}
      />
    </div>
  );
}
