/**
 * VoiceFlow Dedicated Mic Widget Component
 *
 * A standalone, floating mic widget that appears automatically when the app opens
 * and can be positioned anywhere on screen. Provides quick dictation access
 * with visual feedback for recording status.
 * 
 * Works in two modes:
 * 1. Embedded in main window (position managed by React state + localStorage)
 * 2. Overlay window (position managed by Tauri window API)
 */

import { useState, useEffect, useRef, useCallback } from 'react';
import { invoke } from '@tauri-apps/api/core';
import { getCurrentWindow, PhysicalPosition } from '@tauri-apps/api/window';

interface MicWidgetProps {
  status: 'idle' | 'recording' | 'transcribing' | 'cleaning' | 'error';
  onToggleRecording: () => void;
  visible?: boolean;  // Whether the widget should be visible (default: true)
}

export default function MicWidget({ status, onToggleRecording, visible = true }: MicWidgetProps) {
  // Detect if running in overlay window (separate Tauri window)
  const isOverlay = window.location.hash === '#overlay';
  const [position, setPosition] = useState({ x: 24, y: 80 });
  const [dragging, setDragging] = useState(false);
  const [dragStart, setDragStart] = useState({ x: 0, y: 0 });
  const widgetRef = useRef<HTMLButtonElement>(null);

  // In overlay mode, position is managed by Tauri window
  // In embedded mode, position is managed by React state + localStorage
  useEffect(() => {
    if (isOverlay) {
      // Get initial position from Tauri window
      getCurrentWindow().outerPosition().then(pos => {
        setPosition({ x: pos.x, y: pos.y });
      }).catch(console.error);

      // Listen for window move events to save position
      const unlisten = getCurrentWindow().onMoved(() => {
        getCurrentWindow().outerPosition().then(pos => {
          setPosition({ x: pos.x, y: pos.y });
        }).catch(console.error);
      });
      unlisten.then(unlisten => unlisten());
    } else {
      // Embedded mode: load from localStorage
      const saved = localStorage.getItem('voiceflow::mic-widget-pos');
      if (saved) {
        try {
          const pos = JSON.parse(saved);
          setPosition(pos);
        } catch (e) {
          // Use default
        }
      }
    }
  }, [isOverlay]);

  // Mouse drag handlers for repositioning
  const handleMouseDown = (e: React.MouseEvent) => {
    if (status === 'recording') return;

    e.preventDefault();
    
    if (isOverlay) {
      // In overlay mode, start Tauri window drag
      getCurrentWindow().startDragging().catch(console.error);
    } else {
      // In embedded mode, use React drag
      setDragging(true);
      const rect = widgetRef.current?.getBoundingClientRect();
      if (rect) {
        setDragStart({
          x: e.clientX - rect.left,
          y: e.clientY - rect.top
        });
      }
    }
  };

  const handleMouseMove = useCallback((e: MouseEvent) => {
    if (!dragging || isOverlay) return;

    const newX = e.clientX - dragStart.x;
    const newY = e.clientY - dragStart.y;

    setPosition({ x: newX, y: newY });
  }, [dragging, dragStart, isOverlay]);

  const handleMouseUp = useCallback(() => {
    if (!dragging || isOverlay) return;

    setDragging(false);
    // Save position to localStorage (embedded mode only)
    if (!isOverlay) {
      localStorage.setItem('voiceflow::mic-widget-pos', JSON.stringify(position));
    }
  }, [dragging, position, isOverlay]);

  useEffect(() => {
    if (dragging && !isOverlay) {
      document.addEventListener('mousemove', handleMouseMove);
      document.addEventListener('mouseup', handleMouseUp);
      return () => {
        document.removeEventListener('mousemove', handleMouseMove);
        document.removeEventListener('mouseup', handleMouseUp);
      };
    }
  }, [dragging, handleMouseMove, handleMouseUp, isOverlay]);

  // Keyboard shortcut: Space to start/stop (only in embedded mode)
  // In overlay mode, global hotkey handles this
  useEffect(() => {
    if (isOverlay) return;

    const handleKeyDown = (e: KeyboardEvent) => {
      // Only respond to Space if we're not in an input/textarea
      const activeElement = document.activeElement;
      if (activeElement && (activeElement.tagName === 'INPUT' || activeElement.tagName === 'TEXTAREA')) {
        return;
      }

      if (e.code === 'Space' && status === 'idle' && visible) {
        e.preventDefault();
        onToggleRecording();
      }
    };

    document.addEventListener('keydown', handleKeyDown);
    return () => document.removeEventListener('keydown', handleKeyDown);
  }, [status, onToggleRecording, visible, isOverlay]);

  // Double-click to reset position (embedded mode only)
  const handleDoubleClick = () => {
    if (isOverlay) {
      // Reset overlay window to default position
      getCurrentWindow().setPosition(new PhysicalPosition(24, 80)).catch(console.error);
    } else {
      localStorage.removeItem('voiceflow::mic-widget-pos');
      setPosition({ x: 24, y: 80 });
    }
  };

  // Right-click / long-press to open main window
  const handleContextMenu = (e: React.MouseEvent) => {
    e.preventDefault();
    invoke('toggle_main_window').catch(console.error);
  };

  // Touch long-press for mobile
  const [touchTimer, setTouchTimer] = useState<number | null>(null);

  const handleTouchStart = () => {
    const timer = setTimeout(() => {
      invoke('toggle_main_window').catch(console.error);
      // Haptic feedback if available
      if ('vibrate' in navigator) {
        navigator.vibrate(10);
      }
    }, 500);
    setTouchTimer(timer);
  };

  const handleTouchEnd = () => {
    if (touchTimer) {
      clearTimeout(touchTimer);
      setTouchTimer(null);
    }
  };

  const isRecording = status === 'recording';

  // Don't render if not visible
  if (!visible) return null;

  return (
    <button
      ref={widgetRef}
      className={`mic-widget ${isRecording ? 'recording' : ''} ${dragging ? 'dragging' : ''} ${isOverlay ? 'overlay-mode' : ''}`}
      onClick={onToggleRecording}
      onDoubleClick={handleDoubleClick}
      onMouseDown={handleMouseDown}
      aria-label={isRecording ? 'Stop recording' : 'Start recording'}
      title={isRecording 
        ? 'Stop recording' 
        : (navigator.platform.includes('Mac') ? 'Start recording (⌘Space)' : 'Start recording (Ctrl+Space)')}
      style={{
        position: isOverlay ? 'relative' : 'fixed',
        left: isOverlay ? undefined : position.x,
        top: isOverlay ? undefined : position.y,
        zIndex: 50,
        cursor: dragging ? 'move' : 'pointer',
        touchAction: 'none'
      }}
      onContextMenu={handleContextMenu}
      onTouchStart={handleTouchStart}
      onTouchEnd={handleTouchEnd}
    >
      {/* Mic SVG Icon */}
      <svg
        viewBox="0 0 24 24"
        width="48"
        height="48"
        fill="none"
        stroke="currentColor"
        strokeWidth={isRecording ? 3 : 2.5}
        strokeLinecap="round"
        strokeLinejoin="round"
        aria-hidden="true"
      >
        {/* Mic Graph */}
        <path d="M12 2a3 3 0 0 0-3 3v7a3 3 0 0 0 6 0V5a3 3 0 0 0-3-3z" />
        {/* Sound waves - only show when recording */}
        {isRecording && (
          <>
            <path d="M19 10a7 7 0 0 1-14 0" />
            <path d="M12 14.5V18" />
            <line x1="9" y1="14.5" x2="15" y2="14.5" />
          </>
        )}
      </svg>
    </button>
  );
}
