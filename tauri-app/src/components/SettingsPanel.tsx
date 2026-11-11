import { useState } from 'react';
import { HardwareProfile, ListedModel } from '../types';

interface SettingsPanelProps {
  settings: {
    language: string;
    autoPaste: boolean;
    whisperModel: string;
    cleanupModel: string;
    showMicWidget?: boolean;
    silenceTimeoutMs?: number;
    doubleClickEnabled?: boolean;
  };
  hardware?: HardwareProfile | null;
  models: ListedModel[];
  isDownloading: Record<string, boolean>;
  onSave: (settings: any) => void;
  onClose: () => void;
  onDownload: (url: string, filename: string, sizeMb: number, sha256?: string) => void;
}

const LANGUAGES = [
  { code: 'en', name: 'English' },
  { code: 'sv', name: 'Swedish' },
  { code: 'de', name: 'German' },
  { code: 'fr', name: 'French' },
  { code: 'es', name: 'Spanish' },
  { code: 'auto', name: 'Auto-detect' },
];

const WHISPER_MODELS = [
  { id: 'tiny', name: 'Tiny (75 MB)', size: 75 },
  { id: 'base', name: 'Base (148 MB)', size: 148 },
  { id: 'small', name: 'Small (488 MB)', size: 488 },
  { id: 'medium', name: 'Medium (1.5 GB)', size: 1500 },
  { id: 'large-v3-turbo', name: 'Large-v3-turbo (1.6 GB)', size: 1600 },
];

function recommendedWhisperId(hardware: HardwareProfile): string {
  const id = hardware.recommended_model_id?.trim();
  if (id && WHISPER_MODELS.some(model => model.id === id)) {
    return id;
  }
  const file = (hardware.recommended_whisper_model || '').toLowerCase();
  if (file.includes('large-v3-turbo')) return 'large-v3-turbo';
  if (file.includes('medium')) return 'medium';
  if (file.includes('small')) return 'small';
  if (file.includes('tiny')) return 'tiny';
  return 'base';
}

function englishModelFilename(id: string): string {
  if (id === 'large-v3-turbo') return 'ggml-large-v3-turbo.bin';
  if (id === 'tiny' || id === 'base' || id === 'small' || id === 'medium') {
    return `ggml-${id}.en.bin`;
  }
  return 'ggml-base.en.bin';
}

export default function SettingsPanel({
  settings,
  hardware,
  models,
  isDownloading,
  onSave,
  onClose,
  onDownload
}: SettingsPanelProps) {
  const [localSettings, setLocalSettings] = useState({
    ...settings,
    silenceTimeoutMs: settings.silenceTimeoutMs ?? 2000,
    doubleClickEnabled: settings.doubleClickEnabled ?? true,
    showMicWidget: settings.showMicWidget ?? true,
  });

  const handleSave = () => {
    onSave(localSettings);
  };

  const handleApplyRecommended = () => {
    if (!hardware) return;
    setLocalSettings(prev => ({
      ...prev,
      whisperModel: recommendedWhisperId(hardware),
      cleanupModel: 'off',
    }));
  };

  const whisperModel = WHISPER_MODELS.find(m => m.id === localSettings.whisperModel);
  const whisperFile = englishModelFilename(localSettings.whisperModel);
  const whisperDownloaded = models.some(m => m.filename === whisperFile && m.downloaded);

  return (
    <div className="settings-panel">
      <div className="settings-header">
        <h2>VoiceFlow Settings</h2>
        <button className="close-btn" onClick={onClose}>×</button>
      </div>

      <div className="settings-content">
        {/* Ghost Pepper Hardware Profiling Card */}
        {hardware && (
          <div className="hardware-card">
            <div className="hardware-card-header">
              <span className="hardware-title">
                <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                  <rect x="4" y="4" width="16" height="16" rx="2"/>
                  <rect x="9" y="9" width="6" height="6"/>
                  <line x1="9" y1="1" x2="9" y2="4"/>
                  <line x1="15" y1="1" x2="15" y2="4"/>
                  <line x1="9" y1="20" x2="9" y2="23"/>
                  <line x1="15" y1="20" x2="15" y2="23"/>
                  <line x1="20" y1="9" x2="23" y2="9"/>
                  <line x1="20" y1="14" x2="23" y2="14"/>
                  <line x1="1" y1="9" x2="4" y2="9"/>
                  <line x1="1" y1="14" x2="4" y2="14"/>
                </svg>
                Ghost Pepper Profiler
              </span>
              <span className="tier-badge">{hardware.recommended_tier}</span>
            </div>
            <div className="hardware-specs">
              <span className="spec-chip">{hardware.cpu_brand || 'CPU'}</span>
              <span className="spec-chip">{Math.round(hardware.total_ram_mb / 1024)} GB RAM</span>
              <span className="spec-chip">{hardware.cpu_cores} Cores</span>
            </div>
            <div className="hardware-details">
              Recommended speech model: <strong>{hardware.recommended_whisper_model}</strong>
            </div>
            <button
              type="button"
              className="btn-download"
              style={{ marginTop: '4px', alignSelf: 'flex-start' }}
              onClick={handleApplyRecommended}
            >
              Apply Recommended Config
            </button>
          </div>
        )}

        {/* Hotkey notice */}
        <div className="setting-hint" style={{ background: 'rgba(255,255,255,0.03)', padding: '8px 10px', borderRadius: '6px' }}>
          💡 <strong>Global Hotkey:</strong> <kbd>Option+Space</kbd> (macOS) / <kbd>Ctrl+Space</kbd> (Win/Linux). Tap <kbd>Esc</kbd> anytime to cancel.
        </div>

        {/* Wispr Flow Double-Click & VAD Section */}
        <div className="setting-group setting-row">
          <div>
            <label>Hands-Free Double-Tap</label>
            <div className="setting-hint">Double-tap hotkey to toggle hands-free dictation</div>
          </div>
          <input
            type="checkbox"
            checked={localSettings.doubleClickEnabled}
            onChange={e => setLocalSettings({...localSettings, doubleClickEnabled: e.target.checked})}
            className="toggle"
          />
        </div>

        <div className="setting-group slider-container">
          <label>Silence Auto-Stop Duration</label>
          <div className="slider-row">
            <input
              type="range"
              min="1000"
              max="5000"
              step="250"
              value={localSettings.silenceTimeoutMs}
              onChange={e => setLocalSettings({...localSettings, silenceTimeoutMs: parseInt(e.target.value)})}
              className="slider-input"
            />
            <span className="slider-val">{(localSettings.silenceTimeoutMs / 1000).toFixed(1)}s</span>
          </div>
          <div className="setting-hint">Automatically commits dictation when silence countdown finishes</div>
        </div>

        {/* Handy Floating HUD & Paste Section */}
        <div className="setting-group setting-row">
          <div>
            <label>Floating HUD Widget</label>
            <div className="setting-hint">Show floating live-transcription overlay on screen</div>
          </div>
          <input
            type="checkbox"
            checked={localSettings.showMicWidget}
            onChange={e => setLocalSettings({...localSettings, showMicWidget: e.target.checked})}
            className="toggle"
          />
        </div>

        <div className="setting-group setting-row">
          <div>
            <label>Auto-Paste at Active Cursor</label>
            <div className="setting-hint">Inserts text into active app without focus loss</div>
          </div>
          <input
            type="checkbox"
            checked={localSettings.autoPaste}
            onChange={e => setLocalSettings({...localSettings, autoPaste: e.target.checked})}
            className="toggle"
          />
        </div>

        {/* Language & Model Selection */}
        <div className="setting-group">
          <label>Language</label>
          <select
            value={localSettings.language}
            onChange={e => setLocalSettings({...localSettings, language: e.target.value})}
          >
            {LANGUAGES.map(l => (
              <option key={l.code} value={l.code}>{l.name}</option>
            ))}
          </select>
        </div>

        <div className="setting-group">
          <label>Speech Recognition Model (Whisper)</label>
          <select
            value={localSettings.whisperModel}
            onChange={e => setLocalSettings({...localSettings, whisperModel: e.target.value})}
          >
            {WHISPER_MODELS.map(m => (
              <option key={m.id} value={m.id}>{m.name}</option>
            ))}
          </select>
          <div className="model-status">
            {whisperModel && (
              <span>
                {whisperDownloaded
                  ? `✓ ${whisperFile} downloaded`
                  : `~${whisperModel.size} MB required (${whisperFile})`}
              </span>
            )}
          </div>
        </div>

        <div className="setting-group">
          <label>Text cleanup</label>
          <div className="setting-hint">
            Fillers such as “um” and “uh” are removed, and the sentence is capitalized. A local language model is not used, so paste is not blocked on a download.
          </div>
        </div>

        {/* Manual model downloads */}
        <div className="setting-group">
          <label>Installed & Available Models</label>
          <div className="download-list">
            {models.filter(m => m.url && !m.downloaded).map(m => (
              <div key={m.filename} className="download-item">
                <span className="download-name">{m.name}</span>
                <span className="download-size">{m.sizeMb} MB</span>
                <button
                  className="btn-download"
                  onClick={() => onDownload(m.url, m.filename, m.sizeMb, m.sha256)}
                  disabled={isDownloading[m.filename]}
                >
                  {isDownloading[m.filename] ? 'Downloading...' : 'Download'}
                </button>
              </div>
            ))}
            {models.filter(m => m.url && !m.downloaded).length === 0 && (
              <p className="no-downloads">All local models ready</p>
            )}
          </div>
        </div>
      </div>

      <div className="settings-footer">
        <button className="btn-secondary" onClick={onClose}>Cancel</button>
        <button className="btn-primary" onClick={handleSave}>Save Settings</button>
      </div>
    </div>
  );
}
