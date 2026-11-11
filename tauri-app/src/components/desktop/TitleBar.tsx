import React from 'react';
import { getCurrentWindow } from '@tauri-apps/api/window';

export default function TitleBar() {
  const handleClose = async () => {
    try {
      const win = getCurrentWindow();
      await win.hide();
    } catch {
      // In web browser context
      window.close();
    }
  };

  const handleMinimize = async () => {
    try {
      const win = getCurrentWindow();
      await win.minimize();
    } catch {
      // Ignore in web context
    }
  };

  const handleZoom = async () => {
    try {
      const win = getCurrentWindow();
      const isMaximized = await win.isMaximized();
      if (isMaximized) {
        await win.unmaximize();
      } else {
        await win.maximize();
      }
    } catch {
      // Ignore in web context
    }
  };

  return (
    <header className="desktop-titlebar">
      <div className="traffic-lights">
        <button
          type="button"
          className="traffic-light close"
          onClick={handleClose}
          title="Close window"
          aria-label="Close"
        />
        <button
          type="button"
          className="traffic-light minimize"
          onClick={handleMinimize}
          title="Minimize window"
          aria-label="Minimize"
        />
        <button
          type="button"
          className="traffic-light zoom"
          onClick={handleZoom}
          title="Zoom window"
          aria-label="Zoom"
        />
      </div>
      <div className="titlebar-title">VoiceFlow</div>
    </header>
  );
}
