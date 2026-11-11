// TypeScript types for VoiceFlow

export type AppStatus =
  | 'idle'
  | 'recording'
  | 'hands_free'
  | 'transcribing'
  | 'cleaning'
  | 'success'
  | 'error';

export interface HardwareProfile {
  os: string;
  arch: string;
  cpu_brand: string;
  cpu_cores: number;
  total_ram_mb: number;
  is_apple_silicon: boolean;
  apple_silicon_family?: string;
  recommended_tier: 'Tier1Low' | 'Tier2Mid' | 'Tier3High' | 'Tier4Extreme';
  recommended_model_id?: string;
  recommended_whisper_model: string;
  recommended_cleanup_model: string;
}

export interface ModelInfo {
  name: string;
  filename: string;
  url: string;
  size_mb: number;
  sha256?: string;
  downloaded: boolean;
}

/** Model row after the settings window maps the Rust payload. */
export interface ListedModel {
  name: string;
  filename: string;
  downloaded: boolean;
  sizeMb: number;
  url: string;
  sha256?: string;
}

export interface AppSettings {
  language: string;
  auto_paste: boolean;
  show_mic_widget: boolean;
  output_device?: string;
  whisper_model: string;
  cleanup_model: string;
  silence_timeout_ms: number;
  double_click_enabled: boolean;
  transcribe_shortcut?: string;
  push_to_talk?: boolean;
  microphone?: string;
  mute_while_recording?: boolean;
  audio_feedback?: boolean;
  feedback_volume?: number;
}

export interface VadCountdownPayload {
  remaining_ms: number;
  progress: number;
  active?: boolean;
}
