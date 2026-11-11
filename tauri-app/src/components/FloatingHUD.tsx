import React, { useState, useEffect, useRef } from 'react';
import {
  getCurrentWindow,
  currentMonitor,
  primaryMonitor,
  LogicalSize,
  PhysicalPosition,
} from '@tauri-apps/api/window';
import { useAudioVisualizer } from '../hooks/useAudioVisualizer';
import { AppStatus } from '../types';
import './FloatingHUD.css';

interface FloatingHUDProps {
  status: AppStatus;
  liveTranscript?: string;
  errorMessage?: string;
  onToggleRecording: () => void;
  onCancel: () => void;
  visible?: boolean;
}

const STORAGE_KEY = 'voiceflow::widget-pos';
const PILL_WIDTH = 320;
const PILL_HEIGHT = 56;
const EXPANDED_WIDTH = 460;
const EXPANDED_HEIGHT = 130;
const SUCCESS_WIDTH = 260;
const SUCCESS_HEIGHT = 52;
const ERROR_WIDTH = 440;
const ERROR_HEIGHT = 76;

export default function FloatingHUD({
  status,
  liveTranscript = '',
  errorMessage = '',
  onToggleRecording,
  onCancel,
  visible = true,
}: FloatingHUDProps) {
  const isRecording = status === 'recording' || status === 'hands_free';
  const isHandsFree = status === 'hands_free';
  const hasText = liveTranscript.trim().length > 0;
  const isExpanded = hasText && (isRecording || status === 'transcribing' || status === 'success');

  const [seconds, setSeconds] = useState(0);
  const textEndRef = useRef<HTMLDivElement>(null);

  const { audioBars, isCountingDown, countdownProgress, remainingMs } = useAudioVisualizer(isRecording);

  const currentSizeRef = useRef<{ width: number; height: number }>({
    width: PILL_WIDTH,
    height: PILL_HEIGHT,
  });
  const isResizingRef = useRef(false);
  const isFirstRender = useRef(true);
  const moveDebounceRef = useRef<number | null>(null);

  // Initial Placement & Persistence
  useEffect(() => {
    let unlistenMoved: (() => void) | undefined;

    const initializePosition = async () => {
      try {
        const win = getCurrentWindow();
        const monitor = (await currentMonitor()) || (await primaryMonitor());
        const scale = (await win.scaleFactor().catch(() => monitor?.scaleFactor || 1)) || 1;

        const monX = monitor?.position?.x ?? 0;
        const monY = monitor?.position?.y ?? 0;
        const monW = monitor?.size?.width ?? 1920;
        const monH = monitor?.size?.height ?? 1080;

        const widgetPhysW = Math.round(PILL_WIDTH * scale);
        const widgetPhysH = Math.round(PILL_HEIGHT * scale);

        // Default bottom-center: centered horizontally, 120 logical px above monitor bottom
        const defaultX = monX + Math.round((monW - widgetPhysW) / 2);
        const defaultY = monY + monH - Math.round(120 * scale) - widgetPhysH;

        let initialX = defaultX;
        let initialY = defaultY;

        const savedRaw = localStorage.getItem(STORAGE_KEY);
        if (savedRaw) {
          try {
            const saved = JSON.parse(savedRaw);
            if (typeof saved.x === 'number' && typeof saved.y === 'number') {
              // Sanity check coordinates to ensure widget is on-screen
              const minX = monX;
              const maxX = monX + monW - Math.round(60 * scale);
              const minY = monY;
              const maxY = monY + monH - Math.round(40 * scale);

              if (saved.x >= minX - 60 && saved.x <= maxX && saved.y >= minY - 40 && saved.y <= maxY) {
                initialX = Math.round(Math.max(minX, Math.min(saved.x, monX + monW - widgetPhysW)));
                initialY = Math.round(Math.max(minY, Math.min(saved.y, monY + monH - widgetPhysH)));
              }
            }
          } catch {
            // Use defaults if parse fails
          }
        }

        // Apply initial position and size
        await win.setPosition(new PhysicalPosition(initialX, initialY));
        await win.setSize(new LogicalSize(PILL_WIDTH, PILL_HEIGHT));

        // Listen to window movement (debounced ~250ms)
        const unlisten = await win.onMoved(async () => {
          if (isResizingRef.current) return;

          if (moveDebounceRef.current) {
            window.clearTimeout(moveDebounceRef.current);
          }

          moveDebounceRef.current = window.setTimeout(async () => {
            try {
              if (isResizingRef.current) return;
              const pos = await win.outerPosition();
              const sFactor = (await win.scaleFactor().catch(() => 1)) || 1;

              // Normalize to base pill position so restorations on relaunch match anchor
              const curH = currentSizeRef.current.height;
              const curW = currentSizeRef.current.width;
              const deltaH = (curH - PILL_HEIGHT) * sFactor;
              const deltaW = (curW - PILL_WIDTH) * sFactor;
              const pillX = Math.round(pos.x + deltaW / 2);
              const pillY = Math.round(pos.y + deltaH);

              localStorage.setItem(STORAGE_KEY, JSON.stringify({ x: pillX, y: pillY }));
            } catch {
              // Ignore in web context
            }
          }, 250);
        });

        unlistenMoved = unlisten;
      } catch (err) {
        console.error('HUD positioning initialization error:', err);
      }
    };

    initializePosition();

    return () => {
      if (moveDebounceRef.current) {
        window.clearTimeout(moveDebounceRef.current);
      }
      if (unlistenMoved) {
        unlistenMoved();
      }
    };
  }, []);

  // Smooth Bottom-Anchored Resizing
  useEffect(() => {
    if (isFirstRender.current) {
      isFirstRender.current = false;
      return;
    }

    const targetSize = isExpanded
      ? { width: EXPANDED_WIDTH, height: EXPANDED_HEIGHT }
      : status === 'error'
      ? { width: ERROR_WIDTH, height: ERROR_HEIGHT }
      : status === 'success'
      ? { width: SUCCESS_WIDTH, height: SUCCESS_HEIGHT }
      : { width: PILL_WIDTH, height: PILL_HEIGHT };

    const oldSize = currentSizeRef.current;
    if (oldSize.width === targetSize.width && oldSize.height === targetSize.height) {
      return;
    }

    currentSizeRef.current = targetSize;

    const resizeBottomAnchored = async () => {
      try {
        const win = getCurrentWindow();
        const scale = (await win.scaleFactor().catch(() => 1)) || 1;
        const deltaY = Math.round((targetSize.height - oldSize.height) * scale);
        const deltaX = Math.round((targetSize.width - oldSize.width) * scale);

        isResizingRef.current = true;
        const pos = await win.outerPosition();

        // Adjust position upward (and center horizontally) so expansion is bottom-anchored
        await win.setPosition(
          new PhysicalPosition(
            pos.x - Math.round(deltaX / 2),
            pos.y - deltaY
          )
        );
        await win.setSize(new LogicalSize(targetSize.width, targetSize.height));

        window.setTimeout(() => {
          isResizingRef.current = false;
        }, 350);
      } catch {
        isResizingRef.current = false;
      }
    };

    resizeBottomAnchored();
  }, [isExpanded, status]);

  // Recording timer
  useEffect(() => {
    let timer: number | null = null;
    if (isRecording) {
      timer = window.setInterval(() => setSeconds(s => s + 1), 1000);
    } else {
      setSeconds(0);
    }
    return () => {
      if (timer) clearInterval(timer);
    };
  }, [isRecording]);

  // Auto-scroll live transcript
  useEffect(() => {
    if (textEndRef.current) {
      textEndRef.current.scrollIntoView({ behavior: 'smooth' });
    }
  }, [liveTranscript]);

  // Global Esc key listener
  useEffect(() => {
    const handleKeyDown = (e: KeyboardEvent) => {
      if (e.key === 'Escape' && (isRecording || status === 'transcribing' || status === 'error')) {
        e.preventDefault();
        onCancel();
      }
    };
    window.addEventListener('keydown', handleKeyDown);
    return () => window.removeEventListener('keydown', handleKeyDown);
  }, [isRecording, status, onCancel]);

  if (!visible) return null;

  const formatTimer = (totalSec: number) => {
    const mins = Math.floor(totalSec / 60);
    const secs = totalSec % 60;
    return `${String(mins).padStart(2, '0')}:${String(secs).padStart(2, '0')}`;
  };

  const handleDragStart = (e: React.MouseEvent) => {
    const target = e.target as HTMLElement | null;
    if (!target) return;
    if (
      target.closest('[data-tauri-drag-region="false"]') ||
      target.closest('button') ||
      target.closest('.mic-indicator-wrapper') ||
      target.closest('.hud-transcript-body')
    ) {
      return;
    }
    try {
      getCurrentWindow().startDragging().catch(() => {});
    } catch {
      // Ignore
    }
  };

  const handleGripMouseDown = (e: React.MouseEvent) => {
    e.stopPropagation();
    try {
      getCurrentWindow().startDragging().catch(() => {});
    } catch {
      // Ignore
    }
  };

  // 6-dot drag handle icon component
  const dragGripHandle = (
    <div
      className="hud-drag-handle"
      data-tauri-drag-region
      onMouseDown={handleGripMouseDown}
      title="Drag to reposition"
    >
      <svg width="8" height="14" viewBox="0 0 8 14" fill="currentColor">
        <circle cx="2" cy="2" r="1.2" />
        <circle cx="6" cy="2" r="1.2" />
        <circle cx="2" cy="7" r="1.2" />
        <circle cx="6" cy="7" r="1.2" />
        <circle cx="2" cy="12" r="1.2" />
        <circle cx="6" cy="12" r="1.2" />
      </svg>
    </div>
  );

  // Success State
  if (status === 'success') {
    return (
      <div className="voice-hud-root" onMouseDown={handleDragStart} data-tauri-drag-region>
        <div className="hud-capsule success-state" data-tauri-drag-region>
          {dragGripHandle}
          <div className="success-icon-badge" data-tauri-drag-region="false">
            <svg viewBox="0 0 20 20" fill="currentColor" width="14" height="14">
              <path fillRule="evenodd" d="M16.707 5.293a1 1 0 010 1.414l-8 8a1 1 0 01-1.414 0l-4-4a1 1 0 011.414-1.414L8 12.586l7.293-7.293a1 1 0 011.414 0z" clipRule="evenodd"/>
            </svg>
          </div>
          <span className="success-label" data-tauri-drag-region>Pasted to cursor!</span>
        </div>
      </div>
    );
  }

  // Cleaning State
  if (status === 'cleaning') {
    return (
      <div className="voice-hud-root" onMouseDown={handleDragStart} data-tauri-drag-region>
        <div className="hud-capsule cleaning-state" data-tauri-drag-region>
          {dragGripHandle}
          <div className="cleaning-spinner" data-tauri-drag-region="false" />
          <span className="cleaning-label" data-tauri-drag-region>Polishing transcript...</span>
        </div>
      </div>
    );
  }

  // Error State
  if (status === 'error') {
    return (
      <div className="voice-hud-root" onMouseDown={handleDragStart} data-tauri-drag-region>
        <div className="hud-capsule error-state" data-tauri-drag-region>
          {dragGripHandle}
          <span className="error-label" data-tauri-drag-region>{errorMessage || 'Something went wrong'}</span>
          <button
            className="hud-cancel-btn"
            data-tauri-drag-region="false"
            onClick={(e) => {
              e.stopPropagation();
              onCancel();
            }}
            title="Dismiss"
          >
            ✕
          </button>
        </div>
      </div>
    );
  }

  // Transcribing State
  if (status === 'transcribing') {
    return (
      <div className="voice-hud-root" onMouseDown={handleDragStart} data-tauri-drag-region>
        <div className={`hud-container ${isExpanded ? 'expanded' : 'pill'}`} data-tauri-drag-region>
          <div className="hud-header" data-tauri-drag-region>
            {dragGripHandle}
            <div className="cleaning-spinner" data-tauri-drag-region="false" />
            <span className="cleaning-label" data-tauri-drag-region>Transcribing audio...</span>
            <button
              className="hud-cancel-btn"
              data-tauri-drag-region="false"
              onClick={(e) => {
                e.stopPropagation();
                onCancel();
              }}
              title="Cancel (Esc)"
            >
              ✕
            </button>
          </div>
          {isExpanded && (
            <div className="hud-transcript-body" data-tauri-drag-region="false">
              <div className="transcript-scroll-area" data-tauri-drag-region="false">
                <p className="transcript-text" data-tauri-drag-region="false">
                  {liveTranscript}
                  <span className="live-typing-caret" />
                </p>
                <div ref={textEndRef} />
              </div>
            </div>
          )}
        </div>
      </div>
    );
  }

  // Recording or Idle State
  return (
    <div className="voice-hud-root" onMouseDown={handleDragStart} data-tauri-drag-region>
      <div
        className={`hud-container ${isExpanded ? 'expanded' : 'pill'} ${isCountingDown ? 'counting-down' : ''}`}
        data-tauri-drag-region
      >
        {/* Top Control Header */}
        <div className="hud-header" data-tauri-drag-region>
          {/* Drag Grip Handle */}
          {dragGripHandle}

          {/* Mic Button with Radial Silence Countdown */}
          <div
            className="mic-indicator-wrapper"
            data-tauri-drag-region="false"
            onClick={onToggleRecording}
            title={isRecording ? "Click to Stop (or press shortcut)" : "Click to Record (or double-tap for Hands-Free)"}
          >
            <svg className="silence-ring-svg" viewBox="0 0 32 32">
              <circle cx="16" cy="16" r="13" className="ring-track" />
              {isCountingDown && (
                <circle
                  cx="16"
                  cy="16"
                  r="13"
                  className="ring-progress"
                  style={{
                    strokeDasharray: 81.68,
                    strokeDashoffset: 81.68 * countdownProgress,
                  }}
                />
              )}
            </svg>

            <div className={`mic-circle ${isRecording ? 'active' : ''}`}>
              <svg viewBox="0 0 24 24" width="13" height="13" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round">
                <path d="M12 2a3 3 0 0 0-3 3v7a3 3 0 0 0 6 0V5a3 3 0 0 0-3-3z"/>
                <path d="M19 10a7 7 0 0 1-14 0"/>
                <line x1="12" y1="19" x2="12" y2="22"/>
              </svg>
            </div>
          </div>

          {/* Hands-Free Badge (Wispr Flow style) */}
          {isHandsFree ? (
            <div className="badge-hands-free" data-tauri-drag-region="false">
              <span className="badge-icon">∞</span>
              <span className="badge-text">HANDS-FREE</span>
            </div>
          ) : (
            isRecording && (
              <div className="badge-rec" data-tauri-drag-region="false">
                <span className="rec-dot" />
                <span className="badge-text">REC</span>
              </div>
            )
          )}

          {/* Live Waveform (Handy style) */}
          <div className="waveform-cluster" data-tauri-drag-region>
            {audioBars.map((heightScale, i) => (
              <span
                key={i}
                className="wave-bar"
                style={{
                  height: `${Math.round(4 + heightScale * 18)}px`,
                  opacity: Math.max(0.4, heightScale),
                }}
              />
            ))}
          </div>

          {/* Duration Timer */}
          <div className="duration-timer" data-tauri-drag-region>
            {isRecording ? formatTimer(seconds) : 'VoiceFlow'}
          </div>

          {/* Action Hints or Countdown Alert */}
          <div className="hud-action-hints" data-tauri-drag-region>
            {isCountingDown ? (
              <span className="silence-warn-text">Auto-pasting in {(remainingMs / 1000).toFixed(1)}s</span>
            ) : isHandsFree ? (
              <span className="hint-text">Double-tap stop • Esc</span>
            ) : isRecording ? (
              <span className="hint-text">Release/Tap to stop</span>
            ) : (
              <span className="hint-text">⌥ Space to talk</span>
            )}
          </div>

          {/* Cancel button if active */}
          {isRecording && (
            <button
              className="hud-cancel-btn"
              data-tauri-drag-region="false"
              onClick={(e) => {
                e.stopPropagation();
                onCancel();
              }}
              title="Cancel (Esc)"
            >
              ✕
            </button>
          )}
        </div>

        {/* Live Streaming Transcript Panel */}
        {isExpanded && (
          <div className="hud-transcript-body" data-tauri-drag-region="false">
            <div className="transcript-scroll-area" data-tauri-drag-region="false">
              <p className="transcript-text" data-tauri-drag-region="false">
                {liveTranscript}
                <span className="live-typing-caret" />
              </p>
              <div ref={textEndRef} />
            </div>
          </div>
        )}
      </div>
    </div>
  );
}
