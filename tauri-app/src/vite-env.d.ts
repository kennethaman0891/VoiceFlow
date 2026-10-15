/**
 * VoiceFlow v2 — Global TypeScript declarations
 * Provides type definitions for Tauri interop and browser APIs
 */

// Tauri event payload types
declare global {
  interface Window {
    __TAURI_INTERNALS__?: any;
    __TAURI__?: any;
  }
}

export {};
