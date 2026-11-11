import React, { useState, useEffect } from 'react';
import SettingRow from './SettingRow';

interface GeneralViewProps {
  settings: {
    transcribeShortcut: string;
    pushToTalk: boolean;
    language: string;
    microphone: string;
    muteWhileRecording: boolean;
    audioFeedback: boolean;
    outputDevice: string;
    feedbackVolume: number;
  };
  availableMicrophones: string[];
  onChange: (key: string, value: any) => void;
  onResetKey: (key: string) => void;
}

const LANGUAGES = [
  { code: 'en', name: 'English' },
  { code: 'auto', name: 'Auto-detect' },
  { code: 'es', name: 'Spanish' },
  { code: 'fr', name: 'French' },
  { code: 'de', name: 'German' },
  { code: 'sv', name: 'Swedish' },
  { code: 'it', name: 'Italian' },
  { code: 'pt', name: 'Portuguese' },
  { code: 'ja', name: 'Japanese' },
  { code: 'zh', name: 'Chinese' },
];

export default function GeneralView({
  settings,
  availableMicrophones,
  onChange,
  onResetKey,
}: GeneralViewProps) {
  const [isRecordingKey, setIsRecordingKey] = useState(false);

  // Shortcut key capturer
  useEffect(() => {
    if (!isRecordingKey) return;

    const handleKeyDown = (e: KeyboardEvent) => {
      e.preventDefault();
      e.stopPropagation();

      if (e.key === 'Escape') {
        setIsRecordingKey(false);
        return;
      }

      const modifiers: string[] = [];
      if (e.metaKey) modifiers.push('Command');
      if (e.ctrlKey) modifiers.push('Control');
      if (e.altKey) modifiers.push('Left Option');
      if (e.shiftKey) modifiers.push('Shift');

      let mainKey = e.key;
      if (['Control', 'Alt', 'Shift', 'Meta'].includes(mainKey)) {
        return; // Wait for the trailing non-modifier key
      }

      if (mainKey === ' ') mainKey = 'Space';
      if (mainKey.length === 1) mainKey = mainKey.toUpperCase();

      const combo = [...modifiers, mainKey].join(' + ');
      onChange('transcribeShortcut', combo);
      setIsRecordingKey(false);
    };

    window.addEventListener('keydown', handleKeyDown, true);
    return () => window.removeEventListener('keydown', handleKeyDown, true);
  }, [isRecordingKey, onChange]);

  const mics = availableMicrophones.length > 0 
    ? availableMicrophones 
    : ['MacBook Pro Microphone', 'Built-in Audio', 'Default'];

  return (
    <div className="general-view">
      {/* SECTION 1: GENERAL */}
      <section className="settings-section">
        <div className="section-header">GENERAL</div>
        <div className="settings-card">
          <SettingRow
            label="Transcribe Shortcut"
            tooltip="Hold Option+Space to dictate. Double-tap the Option key for hands-free: VoiceFlow listens until you pause, then inserts the text. Double-tap Option again to insert early. Escape cancels."
            onReset={() => onResetKey('transcribeShortcut')}
          >
            <button
              type="button"
              className={`shortcut-button ${isRecordingKey ? 'recording' : ''}`}
              onClick={() => setIsRecordingKey(!isRecordingKey)}
              title="Click and press key combination to rebind"
            >
              {isRecordingKey ? 'Press shortcut (Esc to cancel)...' : settings.transcribeShortcut}
            </button>
          </SettingRow>

          <SettingRow
            label="Push To Talk"
            tooltip="Hold the shortcut while speaking; release immediately to transcribe and paste."
            showReset={false}
          >
            <label className="toggle-switch">
              <input
                type="checkbox"
                checked={settings.pushToTalk}
                onChange={(e) => onChange('pushToTalk', e.target.checked)}
              />
              <span className="toggle-slider" />
            </label>
          </SettingRow>
          <p className="hotkey-caption">
            Hold Option+Space to dictate. Double-tap Option for hands-free.
          </p>
        </div>
      </section>

      {/* SECTION 2: MODEL SETTINGS */}
      <section className="settings-section">
        <div className="section-header">WHISPER SETTINGS</div>
        <div className="settings-card">
          <SettingRow
            label="Language"
            tooltip="Primary language spoken during dictation. Selecting your language improves transcription accuracy."
            onReset={() => onResetKey('language')}
          >
            <div className="select-wrapper">
              <select
                className="desktop-select"
                value={settings.language}
                onChange={(e) => onChange('language', e.target.value)}
              >
                {LANGUAGES.map((lang) => (
                  <option key={lang.code} value={lang.code}>
                    {lang.name}
                  </option>
                ))}
              </select>
              <svg className="select-chevron" viewBox="0 0 16 16" width="12" height="12" fill="currentColor">
                <path d="M7.247 11.14 2.451 5.658C1.885 5.013 2.345 4 3.204 4h9.592a1 1 0 0 1 .753 1.659l-4.796 5.48a1 1 0 0 1-1.506 0z" />
              </svg>
            </div>
          </SettingRow>
        </div>
      </section>

      {/* SECTION 3: SOUND */}
      <section className="settings-section">
        <div className="section-header">SOUND</div>
        <div className="settings-card">
          <SettingRow
            label="Microphone"
            tooltip="The audio input device used for capturing your speech."
            onReset={() => onResetKey('microphone')}
          >
            <div className="select-wrapper">
              <select
                className="desktop-select"
                value={settings.microphone}
                onChange={(e) => onChange('microphone', e.target.value)}
              >
                {mics.map((mic) => (
                  <option key={mic} value={mic}>
                    {mic}
                  </option>
                ))}
              </select>
              <svg className="select-chevron" viewBox="0 0 16 16" width="12" height="12" fill="currentColor">
                <path d="M7.247 11.14 2.451 5.658C1.885 5.013 2.345 4 3.204 4h9.592a1 1 0 0 1 .753 1.659l-4.796 5.48a1 1 0 0 1-1.506 0z" />
              </svg>
            </div>
          </SettingRow>

          <SettingRow
            label="Mute While Recording"
            tooltip="Silences background media playback on your device while you are actively dictating."
            showReset={false}
          >
            <label className="toggle-switch">
              <input
                type="checkbox"
                checked={settings.muteWhileRecording}
                onChange={(e) => onChange('muteWhileRecording', e.target.checked)}
              />
              <span className="toggle-slider" />
            </label>
          </SettingRow>

          <SettingRow
            label="Audio Feedback"
            tooltip="Plays a subtle audio chime when dictation begins and completes."
            showReset={false}
          >
            <label className="toggle-switch">
              <input
                type="checkbox"
                checked={settings.audioFeedback}
                onChange={(e) => onChange('audioFeedback', e.target.checked)}
              />
              <span className="toggle-slider" />
            </label>
          </SettingRow>

          <SettingRow
            label="Output Device"
            tooltip="The speaker or headphones used for playing audio feedback cues."
            onReset={() => onResetKey('outputDevice')}
          >
            <div className="select-wrapper">
              <select
                className="desktop-select"
                value={settings.outputDevice}
                onChange={(e) => onChange('outputDevice', e.target.value)}
              >
                <option value="Default">Default</option>
                <option value="Internal Speakers">Internal Speakers</option>
                <option value="Headphones">Headphones</option>
              </select>
              <svg className="select-chevron" viewBox="0 0 16 16" width="12" height="12" fill="currentColor">
                <path d="M7.247 11.14 2.451 5.658C1.885 5.013 2.345 4 3.204 4h9.592a1 1 0 0 1 .753 1.659l-4.796 5.48a1 1 0 0 1-1.506 0z" />
              </svg>
            </div>
          </SettingRow>

          <SettingRow
            label="Volume"
            tooltip="Adjust the volume of the audio start and stop cues."
            showReset={false}
          >
            <div className="slider-group">
              <input
                type="range"
                className="desktop-slider"
                min="0"
                max="100"
                value={settings.feedbackVolume}
                style={{ '--slider-progress': `${settings.feedbackVolume}%` } as React.CSSProperties}
                onChange={(e) => onChange('feedbackVolume', parseInt(e.target.value, 10))}
              />
              <span className="slider-readout">{settings.feedbackVolume}%</span>
            </div>
          </SettingRow>
        </div>
      </section>
    </div>
  );
}
