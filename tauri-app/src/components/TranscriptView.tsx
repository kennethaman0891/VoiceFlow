import { useEffect, useRef } from 'react';
import { listen } from '@tauri-apps/api/event';

interface TranscriptViewProps {
  transcript: string[];
  onAddTranscript: (text: string) => void;
}

export default function TranscriptView({ transcript, onAddTranscript }: TranscriptViewProps) {
  const scrollRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (scrollRef.current) {
      scrollRef.current.scrollTop = scrollRef.current.scrollHeight;
    }
  }, [transcript]);

  // Listen for transcript events from backend
  useEffect(() => {
    let unlisten: (() => void) | null = null;
    listen('transcript', (event: any) => {
      const text = event?.payload ?? "";
      if (text?.trim()) {
        onAddTranscript(text);
      }
    }).then(l => { unlisten = l; });
    return () => { unlisten?.(); };
  }, [onAddTranscript]);

  return (
    <div className="transcript-view">
      {transcript.length === 0 ? (
        <div className="empty-state">
          <div className="empty-icon">
            <svg viewBox="0 0 24 24" width="48" height="48" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round">
              <path d="M12 1a3 3 0 0 0-3 3v8a3 3 0 0 0 6 0V4a3 3 0 0 0-3-3z"/>
              <path d="M19 10a7 7 0 0 1-14 0"/>
              <line x1="12" y1="19" x2="12" y2="23"/>
              <line x1="8" y1="23" x2="16" y2="23"/>
            </svg>
          </div>
          <p>Press the mic or <kbd>Ctrl+Space</kbd> to start dictating</p>
          <p className="hint">Your words will appear here</p>
        </div>
      ) : (
        <div className="transcript-list" ref={scrollRef} role="log" aria-live="polite">
          {transcript.map((entry, i) => (
            <p key={i} className="transcript-entry">{entry}</p>
          ))}
        </div>
      )}
    </div>
  );
}
