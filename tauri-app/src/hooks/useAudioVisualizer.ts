import { useState, useEffect, useRef } from 'react';
import { listen } from '@tauri-apps/api/event';
import { VadCountdownPayload } from '../types';

const BANDS = 9;

export function useAudioVisualizer(isRecording: boolean) {
  const [audioBars, setAudioBars] = useState<number[]>(() => Array(BANDS).fill(0));
  const [captureReady, setCaptureReady] = useState(false);
  const [isCountingDown, setIsCountingDown] = useState(false);
  const [countdownProgress, setCountdownProgress] = useState(0);
  const [remainingMs, setRemainingMs] = useState(2000);
  const smoothedRef = useRef<number[]>(Array(16).fill(0));

  useEffect(() => {
    if (!isRecording) {
      smoothedRef.current = Array(16).fill(0);
      setAudioBars(Array(BANDS).fill(0));
      setCaptureReady(false);
      setIsCountingDown(false);
      setCountdownProgress(0);
      return;
    }

    let cancelled = false;
    const unlistenLevel = listen<number[]>('audio_levels', (event) => {
      const incoming = Array.isArray(event.payload) ? event.payload : [];
      const smoothed = smoothedRef.current.map((prev, i) => {
        const target = typeof incoming[i] === 'number' ? incoming[i] : 0;
        return prev * 0.7 + target * 0.3;
      });
      smoothedRef.current = smoothed;
      if (!cancelled) {
        setCaptureReady(true);
        setAudioBars(smoothed.slice(0, BANDS));
      }
    });

    const unlistenCountdown = listen<VadCountdownPayload>('vad_countdown', (event) => {
      if (event.payload.active === false) {
        setIsCountingDown(false);
        setCountdownProgress(0);
        return;
      }
      setIsCountingDown(true);
      setCountdownProgress(event.payload.progress);
      setRemainingMs(event.payload.remaining_ms);
    });

    return () => {
      cancelled = true;
      unlistenLevel.then((u) => u());
      unlistenCountdown.then((u) => u());
    };
  }, [isRecording]);

  return { audioBars, captureReady, isCountingDown, countdownProgress, remainingMs };
}
