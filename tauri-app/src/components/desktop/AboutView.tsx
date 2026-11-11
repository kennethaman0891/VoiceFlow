import React from 'react';
import { HardwareProfile } from '../../types';

interface AboutViewProps {
  hardware: HardwareProfile | null;
}

export default function AboutView({ hardware }: AboutViewProps) {
  return (
    <div className="about-view">
      <div style={{ textAlign: 'center', padding: '16px 0 24px 0' }}>
        <span className="bubble-logo" style={{ fontSize: '38px', transform: 'none' }}>
          voiceflow
        </span>
        <h3 style={{ margin: '12px 0 4px 0', fontSize: '16px', color: 'var(--df-text-main)' }}>
          VoiceFlow Desktop
        </h3>
        <p style={{ margin: 0, fontSize: '13px', color: 'var(--df-text-muted)' }}>
          Version 0.2.0 • Offline Speech-to-Text
        </p>
      </div>

      {/* PRIVACY GUARANTEE */}
      <section className="settings-section">
        <div className="section-header">PRIVACY & SECURITY</div>
        <div className="settings-card" style={{ padding: '16px', display: 'flex', flexDirection: 'column', gap: '12px' }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: '12px' }}>
            <span style={{ color: 'var(--df-success)', fontSize: '18px' }}>✓</span>
            <div>
              <div style={{ fontWeight: 600, fontSize: '13px', color: 'var(--df-text-main)' }}>
                100% On-Device Processing
              </div>
              <div style={{ fontSize: '12px', color: 'var(--df-text-muted)' }}>
                Whisper models run completely locally on your hardware.
              </div>
            </div>
          </div>

          <div style={{ display: 'flex', alignItems: 'center', gap: '12px' }}>
            <span style={{ color: 'var(--df-success)', fontSize: '18px' }}>✓</span>
            <div>
              <div style={{ fontWeight: 600, fontSize: '13px', color: 'var(--df-text-main)' }}>
                Zero Telemetry or Analytics
              </div>
              <div style={{ fontSize: '12px', color: 'var(--df-text-muted)' }}>
                No tracking tokens, analytics packets, or user identifiers.
              </div>
            </div>
          </div>

          <div style={{ display: 'flex', alignItems: 'center', gap: '12px' }}>
            <span style={{ color: 'var(--df-success)', fontSize: '18px' }}>✓</span>
            <div>
              <div style={{ fontWeight: 600, fontSize: '13px', color: 'var(--df-text-main)' }}>
                No Audio Leaves Your Computer
              </div>
              <div style={{ fontSize: '12px', color: 'var(--df-text-muted)' }}>
                Your voice is transcribed in memory and never stored in any cloud.
              </div>
            </div>
          </div>
        </div>
      </section>

      {/* SYSTEM HARDWARE DIAGNOSTICS */}
      {hardware && (
        <section className="settings-section">
          <div className="section-header">DEVICE SPECIFICATIONS</div>
          <div className="settings-card" style={{ padding: '16px' }}>
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: '12px', fontSize: '12.5px' }}>
              <div>
                <span style={{ color: 'var(--df-text-dim)' }}>Operating System: </span>
                <span style={{ color: 'var(--df-text-main)' }}>{hardware.os} ({hardware.arch})</span>
              </div>
              <div>
                <span style={{ color: 'var(--df-text-dim)' }}>CPU: </span>
                <span style={{ color: 'var(--df-text-main)' }}>{hardware.cpu_brand || 'Apple Silicon'}</span>
              </div>
              <div>
                <span style={{ color: 'var(--df-text-dim)' }}>Memory: </span>
                <span style={{ color: 'var(--df-text-main)' }}>{Math.round(hardware.total_ram_mb / 1024)} GB Unified RAM</span>
              </div>
              <div>
                <span style={{ color: 'var(--df-text-dim)' }}>Acceleration: </span>
                <span style={{ color: 'var(--df-text-main)' }}>{hardware.is_apple_silicon ? 'Apple Metal (GPU)' : 'CPU'}</span>
              </div>
            </div>
          </div>
        </section>
      )}

      {/* OPEN SOURCE & LICENSE */}
      <section className="settings-section">
        <div className="section-header">OPEN SOURCE</div>
        <div className="settings-card" style={{ padding: '14px 16px', display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
          <span style={{ fontSize: '13px', color: 'var(--df-text-muted)' }}>
            Licensed under MIT & Apache 2.0
          </span>
          <a
            href="https://github.com/kennethaman0891/VoiceFlow"
            target="_blank"
            rel="noreferrer"
            className="action-btn-sm"
            style={{ textDecoration: 'none' }}
          >
            GitHub Repository
          </a>
        </div>
      </section>
    </div>
  );
}
