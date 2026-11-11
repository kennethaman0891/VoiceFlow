import { useState, useEffect } from 'react';
import { listen } from '@tauri-apps/api/event';
import { VadCountdownPayload } from '../types';

export function useAudioVisualizer(isRecording: boolean) {
  const [audioBars, setAudioBars] = useState<number[]>([0.15, 0.15, 0.15, 0.15, 0.15, 0.15, 0.15, 0.15]);
  const [isCountingDown, setIsCountingDown] = useState(false);
  const [countdownProgress, setCountdownProgress] = useState(0);
  const [remainingMs, setRemainingMs] = useState(2000);

  useEffect(() => {
    if (!isRecording) {
      setAudioBars([0.12, 0.12, 0.12, 0.12, 0.12, 0.12, 0.12, 0.12]);
      setIsCountingDown(false);
      setCountdownProgress(0);
      return;
    }

    // Weights to make the 8 bars look like a natural symmetrical voice waveform
    const weights = [0.45, 0.75, 0.95, 1.0, 1.0, 0.95, 0.75, 0.45];

    const unlistenLevel = listen<number>('audio_level', (event) => {
      const level = Math.min(Math.max(event.payload, 0), 1);

      setAudioBars(prev => {
        return weights.map((w, i) => {
          const target = Math.max(0.12, Math.min(1.0, level * w * 1.4));
          // Smooth decay towards target
          return prev[i] * 0.4 + target * 0.6;
        });
      });
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
      unlistenLevel.then(u => u());
      unlistenCountdown.then(u => u());
    };
  }, [isRecording]);

  return { audioBars, isCountingDown, countdownProgress, remainingMs };
}
