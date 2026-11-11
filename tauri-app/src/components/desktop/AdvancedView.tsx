import React from 'react';
import SettingRow from './SettingRow';

interface AdvancedViewProps {
  settings: {
    silenceTimeoutMs: number;
    doubleClickEnabled: boolean;
    autoPaste: boolean;
    showMicWidget: boolean;
    cleanupModel: string;
  };
  onChange: (key: string, value: any) => void;
  onResetKey: (key: string) => void;
}

export default function AdvancedView({
  settings,
  onChange,
  onResetKey,
}: AdvancedViewProps) {
  const silenceSec = (settings.silenceTimeoutMs / 1000).toFixed(1);
  const silencePercent = Math.round(((settings.silenceTimeoutMs - 1000) / 4000) * 100);

  return (
    <div className="advanced-view">
      {/* DICTATION HEURISTICS */}
      <section className="settings-section">
        <div className="section-header">DICTATION HEURISTICS</div>
        <div className="settings-card">
          <SettingRow
            label="Silence Auto-Stop"
            tooltip="Automatically finishes recording and commits transcription when silence is detected."
            showReset={false}
          >
            <div className="slider-group">
              <input
                type="range"
                className="desktop-slider"
                min="1000"
                max="5000"
                step="250"
                value={settings.silenceTimeoutMs}
                style={{ '--slider-progress': `${silencePercent}%` } as React.CSSProperties}
                onChange={(e) => onChange('silenceTimeoutMs', parseInt(e.target.value, 10))}
              />
              <span className="slider-readout">{silenceSec}s</span>
            </div>
          </SettingRow>

          <SettingRow
            label="Double-Tap Hands-Free"
            tooltip="Double-tap the Option key to dictate without holding anything. A pause inserts the text, and a second double-tap inserts it early. Hold Option+Space when you only want to talk while the keys are down."
            showReset={false}
          >
            <label className="toggle-switch">
              <input
                type="checkbox"
                checked={settings.doubleClickEnabled}
                onChange={(e) => onChange('doubleClickEnabled', e.target.checked)}
              />
              <span className="toggle-slider" />
            </label>
          </SettingRow>

          <SettingRow
            label="Auto-Paste at Cursor"
            tooltip="Directly types or pastes transcribed speech into your active application without stealing focus."
            showReset={false}
          >
            <label className="toggle-switch">
              <input
                type="checkbox"
                checked={settings.autoPaste}
                onChange={(e) => onChange('autoPaste', e.target.checked)}
              />
              <span className="toggle-slider" />
            </label>
          </SettingRow>

          <SettingRow
            label="Floating HUD Widget"
            tooltip="Displays a sleek floating mic and waveform pill on screen while you speak."
            showReset={false}
          >
            <label className="toggle-switch">
              <input
                type="checkbox"
                checked={settings.showMicWidget}
                onChange={(e) => onChange('showMicWidget', e.target.checked)}
              />
              <span className="toggle-slider" />
            </label>
          </SettingRow>
        </div>
      </section>

      {/* TEXT POST-PROCESSING */}
      <section className="settings-section">
        <div className="section-header">SMART TEXT PROCESSING</div>
        <div className="settings-card">
          <SettingRow
            label="Filler Word Stripping"
            tooltip="Removes hesitation fillers such as 'um', 'uh', and 'like' while retaining spoken meaning."
            showReset={false}
          >
            <label className="toggle-switch">
              <input
                type="checkbox"
                checked={settings.cleanupModel !== 'off'}
                onChange={(e) => onChange('cleanupModel', e.target.checked ? 'fillers' : 'off')}
              />
              <span className="toggle-slider" />
            </label>
          </SettingRow>

          <SettingRow
            label="Smart Punctuation & Casing"
            tooltip="Restores natural capitalization and sentence punctuation on-device."
            showReset={false}
          >
            <label className="toggle-switch">
              <input
                type="checkbox"
                defaultChecked={true}
                disabled={true}
              />
              <span className="toggle-slider" />
            </label>
          </SettingRow>
        </div>
      </section>
    </div>
  );
}
