import React, { useEffect, useRef, useState } from 'react';
import { getCurrentWindow } from '@tauri-apps/api/window';
import { invoke } from '@tauri-apps/api/core';
import { useAudioVisualizer } from '../hooks/useAudioVisualizer';
import { AppStatus } from '../types';
import './FloatingHUD.css';

interface FloatingHUDProps {
  status: AppStatus;
  liveTranscript?: string;
  errorMessage?: string;
  shortcut?: string;
  notice?: string | null;
  captureWarning?: string;
  onToggleRecording: () => void;
  onCancel: () => void;
  onOpen?: () => void;
  visible?: boolean;
}

type Posture =
  | 'idle'
  | 'arming'
  | 'listening'
  | 'transcribing'
  | 'polishing'
  | 'pasted'
  | 'no_sound'
  | 'copied'
  | 'error';

const MODIFIERS: Record<string, string> = {
  'left option': '⌥',
  'right option': '⌥',
  option: '⌥',
  alt: '⌥',
  'left command': '⌘',
  'right command': '⌘',
  command: '⌘',
  meta: '⌘',
  'left control': '⌃',
  'right control': '⌃',
  control: '⌃',
  ctrl: '⌃',
  shift: '⇧',
  'left shift': '⇧',
  'right shift': '⇧',
};

export function shortcutKeys(raw: string): string[] {
  const parts = raw
    .split('+')
    .map((part) => part.trim())
    .filter(Boolean);
  if (parts.length === 0) return ['Space'];
  return parts.map((part) => {
    const symbol = MODIFIERS[part.toLowerCase()];
    if (symbol) return symbol;
    if (part.toLowerCase() === 'space') return 'Space';
    return part.length === 1 ? part.toUpperCase() : part;
  });
}

function barHeight(level: number): number {
  const v = Math.max(0, Math.min(1, level));
  return Math.max(3, Math.min(18, 3 + Math.pow(v, 0.7) * 15));
}

function Logo({ mode }: { mode: 'idle' | 'arming' | 'live' | 'done' | 'bad' }) {
  return (
    <div className={`vf-logo ${mode}`} aria-hidden="true">
      <span className="vf-logo-bars">
        <i />
        <i />
        <i />
        <i />
      </span>
    </div>
  );
}

function CancelButton({ onCancel }: { onCancel: () => void }) {
  return (
    <button
      type="button"
      className="vf-cancel"
      aria-label="Cancel"
      title="Cancel (Esc)"
      data-tauri-drag-region="false"
      onMouseDown={(event) => {
        event.preventDefault();
        event.stopPropagation();
        onCancel();
      }}
      onClick={(event) => {
        event.preventDefault();
        event.stopPropagation();
      }}
    >
      <svg viewBox="0 0 16 16" width="10" height="10" aria-hidden="true">
        <path d="M4 4 L12 12 M12 4 L4 12" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" />
      </svg>
    </button>
  );
}

export default function FloatingHUD({
  status,
  liveTranscript = '',
  errorMessage = '',
  shortcut = 'Left Option + Space',
  notice = null,
  captureWarning = '',
  onToggleRecording,
  onCancel,
  onOpen,
  visible = true,
}: FloatingHUDProps) {
  const isRecording = status === 'recording' || status === 'hands_free';
  const hasText = liveTranscript.trim().length > 0;
  const copied = status === 'error' && errorMessage.trim().toLowerCase().startsWith('copied');
  const { audioBars, captureReady, isCountingDown, remainingMs } = useAudioVisualizer(isRecording);

  const posture: Posture = notice === 'no_sound' && status === 'idle'
    ? 'no_sound'
    : copied || notice === 'copied'
      ? 'copied'
      : status === 'error'
        ? 'error'
        : status === 'success'
          ? 'pasted'
          : status === 'cleaning'
            ? 'polishing'
            : status === 'transcribing'
              ? 'transcribing'
              : isRecording
                ? captureReady
                  ? 'listening'
                  : 'arming'
                : 'idle';

  const working = posture === 'transcribing' || posture === 'polishing';
  const warning = captureWarning.trim();
  // Handy keeps the transcript sheet open for the whole take, including the
  // moment before the first word arrives. Waiting for text left that area blank.
  const open =
    posture === 'arming' ||
    posture === 'listening' ||
    working ||
    (posture === 'error' && errorMessage.trim().length > 0) ||
    ((posture === 'pasted' || posture === 'copied') && hasText);
  const showCancel = isRecording || working || posture === 'error' || posture === 'copied';
  const showCaret = (posture === 'listening' || posture === 'arming') && !warning;

  const [seconds, setSeconds] = useState(0);
  const textCapRef = useRef<HTMLDivElement>(null);
  const pinnedRef = useRef(true);
  const dragged = useRef(false);

  useEffect(() => {
    let timer: number | null = null;
    if (isRecording && captureReady) {
      timer = window.setInterval(() => setSeconds((value) => value + 1), 1000);
    } else if (!isRecording) {
      setSeconds(0);
    }
    return () => {
      if (timer) window.clearInterval(timer);
    };
  }, [isRecording, captureReady]);

  useEffect(() => {
    const cap = textCapRef.current;
    if (!cap || !pinnedRef.current) return;
    cap.scrollTop = cap.scrollHeight;
  }, [liveTranscript, open]);

  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if (event.key === 'Escape' && posture !== 'idle' && posture !== 'pasted' && posture !== 'no_sound') {
        event.preventDefault();
        onCancel();
      }
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [posture, onCancel]);

  useEffect(() => {
    let unlistenMoved: (() => void) | undefined;
    let cancelled = false;
    // Rust puts one pill on each display. This only remembers a drag,
    // per display, so a second screen is not pulled back onto the first.
    const remember = async () => {
      try {
        const win = getCurrentWindow();
        unlistenMoved = await win.onMoved(async () => {
          if (cancelled) return;
          try {
            const pos = await win.outerPosition();
            await invoke('save_overlay_position', { x: pos.x, y: pos.y });
          } catch {
            // Browser preview has no window.
          }
        });
      } catch {
        // Browser preview has no Tauri window. The card still renders.
      }
    };
    remember();
    return () => {
      cancelled = true;
      if (unlistenMoved) unlistenMoved();
    };
  }, []);

  if (!visible) return null;

  const formatTimer = (total: number) => {
    const mins = Math.floor(total / 60);
    const secs = total % 60;
    return `${mins}:${String(secs).padStart(2, '0')}`;
  };

  const handleDragStart = (event: React.MouseEvent) => {
    const target = event.target as HTMLElement | null;
    if (!target || target.closest('button') || target.closest('.vf-text-cap')) return;
    dragged.current = false;
    const startX = event.clientX;
    const startY = event.clientY;
    const move = (ev: MouseEvent) => {
      const dx = ev.clientX - startX;
      const dy = ev.clientY - startY;
      if (dx * dx + dy * dy < 16) return;
      dragged.current = true;
      window.removeEventListener('mousemove', move);
      try {
        getCurrentWindow().startDragging().catch(() => {});
      } catch {
        // Browser preview.
      }
    };
    const up = () => {
      window.removeEventListener('mousemove', move);
      window.removeEventListener('mouseup', up);
    };
    window.addEventListener('mousemove', move);
    window.addEventListener('mouseup', up);
  };

  const handleCardClick = () => {
    if (dragged.current) return;
    // Idle starts hands-free. A second click commits the take into the focused field.
    // Escape and the close button still discard it.
    if (posture === 'idle' || posture === 'arming' || posture === 'listening') {
      onToggleRecording();
    }
  };

  const handleScroll = () => {
    const cap = textCapRef.current;
    if (!cap) return;
    pinnedRef.current = cap.scrollHeight - cap.scrollTop - cap.clientHeight <= 16;
  };

  const logoMode =
    posture === 'pasted'
      ? 'done'
      : posture === 'error'
        ? 'bad'
        : posture === 'arming' || posture === 'no_sound' || posture === 'copied'
          ? 'arming'
          : posture === 'listening' || working
            ? 'live'
            : 'idle';

  const keys = shortcutKeys(shortcut);

  let center: React.ReactNode;
  let right: React.ReactNode;

  if (posture === 'idle') {
    center = (
      <>
        <span className="vf-bars breath" aria-hidden="true">
          <i /><i /><i /><i /><i />
        </span>
        <span className="vf-word">VoiceFlow</span>
      </>
    );
    right = (
      <>
        <span className="vf-keys" title="Hold Option+Space to dictate. Double-tap Option, or click the pill, for hands-free.">
          {keys.map((key, index) => (
            <span className="vf-key" key={`${key}-${index}`}>{key}</span>
          ))}
          <span className="vf-talk">to talk</span>
        </span>
        {onOpen ? (
          <button
            type="button"
            className="vf-open"
            aria-label="Open VoiceFlow"
            title="Open VoiceFlow"
            data-tauri-drag-region="false"
            onMouseDown={(event) => event.stopPropagation()}
            onClick={(event) => {
              event.stopPropagation();
              onOpen();
            }}
          >
            <svg viewBox="0 0 16 16" width="11" height="11" aria-hidden="true">
              <rect x="2.5" y="2.5" width="11" height="11" rx="2" fill="none" stroke="currentColor" strokeWidth="1.4" />
            </svg>
          </button>
        ) : null}
      </>
    );
  } else if (posture === 'arming' || posture === 'listening') {
    center = (
      <span className={`vf-bars ${posture === 'arming' ? 'arming' : ''}`} aria-hidden="true">
        {audioBars.map((level, index) => (
          <i key={index} style={{ height: `${Math.round(barHeight(posture === 'arming' ? 0 : level))}px` }} />
        ))}
      </span>
    );
    right = (
      <>
        {status === 'hands_free' ? <span className="vf-talk">hands-free</span> : null}
        <span className={`vf-timer ${isCountingDown ? 'warn' : ''}`}>
          {isCountingDown ? `${(remainingMs / 1000).toFixed(1)}s` : captureReady ? formatTimer(seconds) : '0:00'}
        </span>
        <CancelButton onCancel={onCancel} />
      </>
    );
  } else if (working) {
    center = (
      <>
        <span className="vf-spinner" aria-hidden="true" />
        <span className="vf-label">{posture === 'polishing' ? 'Polishing…' : 'Transcribing…'}</span>
      </>
    );
    right = <CancelButton onCancel={onCancel} />;
  } else if (posture === 'pasted') {
    center = <span className="vf-label">Pasted</span>;
    right = null;
  } else if (posture === 'no_sound') {
    center = <span className="vf-label">No sound detected</span>;
    right = null;
  } else if (posture === 'copied') {
    center = <span className="vf-label">Copied · ⌘V to paste</span>;
    right = showCancel ? <CancelButton onCancel={onCancel} /> : null;
  } else {
    center = <span className="vf-label">{errorMessage || 'Something went wrong'}</span>;
    right = <CancelButton onCancel={onCancel} />;
  }

  const cardClass = [
    'vf-card',
    posture,
    open ? 'open' : '',
    working && !open ? 'working' : '',
    posture === 'pasted' || posture === 'no_sound' || posture === 'copied' ? 'toast' : '',
  ]
    .filter(Boolean)
    .join(' ');

  return (
    <div className="voice-hud-root">
      <div
        className={cardClass}
        role="status"
        aria-live="polite"
        aria-label="VoiceFlow dictation"
        data-tauri-drag-region
        onMouseDown={handleDragStart}
        onClick={handleCardClick}
      >
        <div className="vf-text">
          <div className="vf-text-clip">
            <div className="vf-text-cap" ref={textCapRef} onScroll={handleScroll} data-tauri-drag-region="false">
              <p className={hasText ? '' : 'vf-placeholder'}>
                {open
                  ? posture === 'error' && errorMessage.trim()
                    ? errorMessage
                    : hasText
                      ? liveTranscript
                      : warning || (working ? 'Transcribing…' : status === 'hands_free' ? 'Hands-free · pause to insert' : 'Listening…')
                  : null}
                {showCaret ? <span className="vf-caret" /> : null}
              </p>
            </div>
          </div>
        </div>
        <div className="vf-row">
          <div className="vf-left">
            <Logo mode={logoMode} />
          </div>
          <div className="vf-center">{center}</div>
          <div className="vf-right">{right}</div>
        </div>
      </div>
    </div>
  );
}
