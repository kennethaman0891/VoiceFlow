import { useState } from 'react';

interface SettingsPanelProps {
  settings: {
    language: string;
    autoPaste: boolean;
    whisperModel: string;
    cleanupModel: string;
    showMicWidget?: boolean;
  };
  models: Array<{ name: string; filename: string; downloaded: boolean; sizeMb: number; url: string }>;
  isDownloading: Record<string, boolean>;
  onSave: (settings: any) => void;
  onClose: () => void;
  onDownload: (url: string, filename: string, sizeMb: number) => void;
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
];

const CLEANUP_MODELS = [
  { id: 'off', name: 'None (skip cleanup)' },
  { id: 'qwen0.8b', name: 'Qwen 3.5 0.8B Q4_K_M (~500 MB)' },
];

export default function SettingsPanel({
  settings,
  models,
  isDownloading,
  onSave,
  onClose,
  onDownload
}: SettingsPanelProps) {
  const [localSettings, setLocalSettings] = useState(settings);

  const handleSave = () => {
    onSave(localSettings);
  };

  const whisperModel = WHISPER_MODELS.find(m => m.id === localSettings.whisperModel);
  const cleanupModel = CLEANUP_MODELS.find(m => m.id === localSettings.cleanupModel);

  const getDownloadUrl = (modelId: string) => {
    const model = models.find(m => m.filename.includes(modelId) || m.name.toLowerCase().includes(modelId));
    return model?.url;
  };

  return (
    <div className="settings-panel">
      <div className="settings-header">
        <h2>Settings</h2>
        <button className="close-btn" onClick={onClose}>×</button>
      </div>

      <div className="settings-content">
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
          <label>Speech Recognition Model</label>
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
                {models.find(m => m.name === whisperModel.name)?.downloaded
                  ? '✓ Downloaded'
                  : `~${whisperModel.size} MB required`}
              </span>
            )}
          </div>
        </div>

        <div className="setting-group">
          <label>Text Cleanup</label>
          <select
            value={localSettings.cleanupModel}
            onChange={e => setLocalSettings({...localSettings, cleanupModel: e.target.value})}
          >
            {CLEANUP_MODELS.map(m => (
              <option key={m.id} value={m.id}>{m.name}</option>
            ))}
          </select>
          {cleanupModel?.id !== 'off' && (
            <div className="model-status">
              <span>
                {models.find(m => m.name === cleanupModel?.name)?.downloaded
                  ? '✓ Downloaded'
                  : '~500 MB required'}
              </span>
            </div>
          )}
        </div>

        <div className="setting-group setting-row">
          <label>Auto-paste after transcription</label>
          <input
            type="checkbox"
            checked={localSettings.autoPaste}
            onChange={e => setLocalSettings({...localSettings, autoPaste: e.target.checked})}
            className="toggle"
          />
        </div>

        <div className="setting-group setting-row">
          <label>Show mic widget</label>
          <input
            type="checkbox"
            checked={localSettings.showMicWidget ?? true}
            onChange={e => setLocalSettings({...localSettings, showMicWidget: e.target.checked})}
            className="toggle"
            title="Enable the floating mic widget for quick dictation access"
          />
        </div>

        {/* Manual model downloads */}
        <div className="setting-group">
          <label>Manual Downloads</label>
          <div className="download-list">
            {models.filter(m => m.url && !m.downloaded).map(m => (
              <div key={m.filename} className="download-item">
                <span className="download-name">{m.name}</span>
                <span className="download-size">{m.sizeMb} MB</span>
                <button
                  className="btn-download"
                  onClick={() => onDownload(m.url, m.filename, m.sizeMb)}
                  disabled={isDownloading[m.filename]}
                >
                  {isDownloading[m.filename] ? 'Downloading...' : 'Download'}
                </button>
              </div>
            ))}
            {models.filter(m => m.url && !m.downloaded).length === 0 && (
              <p className="no-downloads">All models up to date</p>
            )}
          </div>
        </div>
      </div>

      <div className="settings-footer">
        <button className="btn-secondary" onClick={onClose}>Cancel</button>
        <button className="btn-primary" onClick={handleSave}>Save</button>
      </div>
    </div>
  );
}
