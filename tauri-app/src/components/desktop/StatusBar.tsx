import React, { useState } from 'react';
import { AppStatus, ListedModel } from '../../types';

interface StatusBarProps {
  status: AppStatus;
  activeModel: string;
  models: ListedModel[];
  onSelectModel: (modelId: string) => void;
  onOpenModelsTab: () => void;
}

export default function StatusBar({
  status,
  activeModel,
  models,
  onSelectModel,
  onOpenModelsTab,
}: StatusBarProps) {
  const [checkingUpdate, setCheckingUpdate] = useState(false);
  const [updateMessage, setUpdateMessage] = useState('');

  const isModelLoaded = status === 'idle' || status === 'recording' || status === 'hands_free';
  const isBusy = status === 'transcribing' || status === 'cleaning';
  const isError = status === 'error';

  const dotClass = isError ? 'error' : isBusy ? 'loading' : 'ready';

  const formatModelDisplayName = (id: string) => {
    switch (id) {
      case 'tiny': return 'Whisper Tiny (75 MB)';
      case 'base': return 'Whisper Base (148 MB)';
      case 'small': return 'Whisper Small (488 MB)';
      case 'medium': return 'Whisper Medium (1.5 GB)';
      case 'large-v3-turbo': return 'Whisper Large-v3-turbo';
      case 'groq-stream': return 'Nemotron / Groq Stream';
      default: return `Whisper ${id.toUpperCase()}`;
    }
  };

  const handleCheckUpdates = () => {
    setCheckingUpdate(true);
    setUpdateMessage('Checking...');
    setTimeout(() => {
      setCheckingUpdate(false);
      setUpdateMessage('You are on the latest version');
      setTimeout(() => setUpdateMessage(''), 3000);
    }, 1200);
  };

  return (
    <footer className="desktop-statusbar">
      <div className="status-left" onClick={onOpenModelsTab} title="Click to view Models">
        <span className={`status-dot ${dotClass}`} />
        <span className="status-model-name">
          {formatModelDisplayName(activeModel)}
          <svg viewBox="0 0 16 16" width="12" height="12" fill="currentColor">
            <path d="M7.247 11.14 2.451 5.658C1.885 5.013 2.345 4 3.204 4h9.592a1 1 0 0 1 .753 1.659l-4.796 5.48a1 1 0 0 1-1.506 0z" />
          </svg>
        </span>
      </div>

      <div className="status-right">
        {updateMessage ? (
          <span style={{ color: 'var(--df-success)' }}>{updateMessage}</span>
        ) : (
          <span
            className="status-update-link"
            onClick={handleCheckUpdates}
            role="button"
            tabIndex={0}
          >
            {checkingUpdate ? 'Checking for updates...' : 'Check for updates'}
          </span>
        )}
        <span>•</span>
        <span>v0.2.0</span>
      </div>
    </footer>
  );
}
