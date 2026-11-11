import React from 'react';
import { invoke } from '@tauri-apps/api/core';

type WindowAction = 'close' | 'minimize' | 'zoom';

function control(action: WindowAction) {
  invoke('window_control', { action }).catch((error) => {
    console.error(`Window ${action} failed`, error);
  });
}

function onPress(event: React.MouseEvent<HTMLButtonElement>, action: WindowAction) {
  event.preventDefault();
  event.stopPropagation();
  control(action);
}

export default function TitleBar() {
  return (
    <header className="desktop-titlebar">
      <div className="traffic-lights">
        <button
          type="button"
          className="traffic-light close"
          title="Close"
          aria-label="Close"
          data-tauri-drag-region="false"
          onMouseDown={(event) => onPress(event, 'close')}
        />
        <button
          type="button"
          className="traffic-light minimize"
          title="Minimize"
          aria-label="Minimize"
          data-tauri-drag-region="false"
          onMouseDown={(event) => onPress(event, 'minimize')}
        />
        <button
          type="button"
          className="traffic-light zoom"
          title="Zoom"
          aria-label="Zoom"
          data-tauri-drag-region="false"
          onMouseDown={(event) => onPress(event, 'zoom')}
        />
      </div>
      <div className="titlebar-drag" data-tauri-drag-region>
        <div className="titlebar-title">VoiceFlow</div>
      </div>
    </header>
  );
}
