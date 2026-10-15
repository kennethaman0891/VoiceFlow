interface MenuBarProps {
  onToggleSettings: () => void;
  status: string;
}

const STATUS_TEXT: Record<string, string> = {
  idle: '● Idle',
  recording: '● Recording...',
  transcribing: '◌ Transcribing...',
  cleaning: '◌ Cleaning...',
  error: '● Error',
};

const STATUS_CLASS: Record<string, string> = {
  idle: 'status-idle',
  recording: 'status-recording',
  transcribing: 'status-transcribing',
  cleaning: 'status-cleaning',
  error: 'status-error',
};

export default function MenuBar({ onToggleSettings, status }: MenuBarProps) {
  return (
    <header className="menu-bar">
      <div className="logo">
        <span className="logo-mark">V</span>
        <span className="wordmark">VoiceFlow</span>
        <span className="badge">LOCAL</span>
      </div>

      <div className={`status-pill ${STATUS_CLASS[status] || 'status-idle'}`}>
        {STATUS_TEXT[status] || STATUS_TEXT.idle}
      </div>

      <button
        className="icon-btn"
        onClick={onToggleSettings}
        aria-label="Settings"
        title="Settings"
      >
        <svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
          <circle cx="12" cy="12" r="3"/>
          <path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-4 0v-.09a1.65 1.65 0 0 0-1-1.51 1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1 0-4h.09a1.65 1.65 0 0 0 1.51-1 1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06a1.65 1.65 0 0 0 1.82.33h.01a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z"/>
        </svg>
      </button>
    </header>
  );
}
