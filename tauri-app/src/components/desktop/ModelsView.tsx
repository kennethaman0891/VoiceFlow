import React from 'react';
import { HardwareProfile, ListedModel } from '../../types';

interface ModelsViewProps {
  currentModel: string;
  hardware: HardwareProfile | null;
  models: ListedModel[];
  isDownloading: Record<string, boolean>;
  onSelectModel: (modelId: string) => void;
  onDownloadModel: (url: string, filename: string, sizeMb: number, sha256?: string) => void;
  onApplyRecommended: () => void;
}

const AVAILABLE_WHISPER_MODELS = [
  {
    id: 'tiny',
    filename: 'ggml-tiny.en.bin',
    name: 'Whisper Tiny (English)',
    sizeMb: 75,
    speed: 'Ultra Fast (~80ms)',
    ramRequired: '1 GB',
    accuracy: 'Good for simple commands',
    url: 'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.en.bin',
  },
  {
    id: 'base',
    filename: 'ggml-base.bin',
    name: 'Whisper Base (Multilingual)',
    sizeMb: 148,
    speed: 'Fast (~150ms)',
    ramRequired: '2 GB',
    accuracy: 'Standard daily dictation',
    url: 'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin',
  },
  {
    id: 'small',
    filename: 'ggml-small.en.bin',
    name: 'Whisper Small (English)',
    sizeMb: 488,
    speed: 'Balanced (~350ms)',
    ramRequired: '4 GB',
    accuracy: 'High accuracy for technical speech',
    url: 'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en.bin',
  },
  {
    id: 'medium',
    filename: 'ggml-medium.en.bin',
    name: 'Whisper Medium (English)',
    sizeMb: 1530,
    speed: 'Moderate (~600ms)',
    ramRequired: '8 GB',
    accuracy: 'Very high accuracy, handles accents',
    url: 'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.en.bin',
  },
  {
    id: 'large-v3-turbo',
    filename: 'ggml-large-v3-turbo.bin',
    name: 'Whisper Large v3 Turbo',
    sizeMb: 1638,
    speed: 'High Performance (~400ms on GPU)',
    ramRequired: '8 GB+',
    accuracy: 'State-of-the-art multilingual',
    url: 'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin',
  },
];

export default function ModelsView({
  currentModel,
  hardware,
  models,
  isDownloading,
  onSelectModel,
  onDownloadModel,
  onApplyRecommended,
}: ModelsViewProps) {
  return (
    <div className="models-view">
      {/* Ghost Pepper Hardware Profiling Banner */}
      {hardware && (
        <div className="hardware-banner">
          <div className="hardware-info">
            <h4>
              <svg viewBox="0 0 24 24" width="16" height="16" fill="currentColor">
                <path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm1 15h-2v-6h2v6zm0-8h-2V7h2v2z"/>
              </svg>
              Ghost Pepper System Profiler
            </h4>
            <p>
              {hardware.cpu_brand || 'Apple Silicon'} • {Math.round(hardware.total_ram_mb / 1024)} GB RAM •{' '}
              {hardware.is_apple_silicon ? 'Metal Acceleration Enabled' : 'CPU Threading'} • Recommended:{' '}
              <strong style={{ color: '#fff' }}>{hardware.recommended_model_id || 'base'}</strong>
            </p>
          </div>
          <button
            type="button"
            className="apply-recommended-btn"
            onClick={onApplyRecommended}
          >
            Apply Recommended
          </button>
        </div>
      )}

      {/* Model Catalog */}
      <section className="settings-section">
        <div className="section-header">INSTALLED & AVAILABLE MODELS</div>
        <div className="settings-card">
          {AVAILABLE_WHISPER_MODELS.map((item) => {
            const isInstalled = models.some(
              (m) => (m.filename === item.filename || m.name.toLowerCase().includes(item.id)) && m.downloaded
            );
            const isSelected = currentModel === item.id;
            const downloading = !!isDownloading[item.filename];

            return (
              <div key={item.id} className="setting-row" style={{ padding: '14px 16px' }}>
                <div className="model-row-info">
                  <div style={{ display: 'flex', alignItems: 'center', gap: '8px' }}>
                    <span className="model-row-name">{item.name}</span>
                    {isSelected && <span className="model-badge active">Active</span>}
                    {isInstalled && !isSelected && (
                      <span className="model-badge downloaded">Installed</span>
                    )}
                  </div>
                  <span className="model-row-desc">
                    {item.sizeMb} MB • {item.speed} • {item.accuracy}
                  </span>
                </div>

                <div className="setting-control-col">
                  {downloading ? (
                    <span style={{ fontSize: '12px', color: 'var(--df-accent-pink)' }}>
                      Downloading...
                    </span>
                  ) : isInstalled ? (
                    <button
                      type="button"
                      className={`action-btn-sm ${isSelected ? '' : 'primary'}`}
                      disabled={isSelected}
                      onClick={() => onSelectModel(item.id)}
                    >
                      {isSelected ? 'In Use' : 'Select'}
                    </button>
                  ) : (
                    <button
                      type="button"
                      className="action-btn-sm primary"
                      onClick={() => onDownloadModel(item.url, item.filename, item.sizeMb)}
                    >
                      Download ({item.sizeMb} MB)
                    </button>
                  )}
                </div>
              </div>
            );
          })}
        </div>
      </section>
    </div>
  );
}
