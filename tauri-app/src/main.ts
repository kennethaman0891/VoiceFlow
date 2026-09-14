import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";

const $ = (id: string) => document.getElementById(id) as HTMLElement;

// Detect non-Tauri hosts (plain browser preview) and short-circuit invoke/listen
// so the UI doesn't surface transport errors while still rendering correctly.
const IS_TAURI =
  typeof (globalThis as any).__TAURI_INTERNALS__ !== "undefined" ||
  typeof (window as any).__TAURI__ !== "undefined";

const safeInvoke = async <T = any>(cmd: string, args?: any): Promise<T | null> => {
  if (!IS_TAURI) {
    console.warn(`[voiceflow] invoke('${cmd}') skipped — not running in Tauri.`);
    return null;
  }
  return (await invoke(cmd, args)) as T;
};

const safeListen = async (
  event: string,
  handler: (e: { payload: any }) => void
): Promise<() => void> => {
  if (!IS_TAURI) return () => {};
  const unlisten = await listen(event, handler as any);
  return unlisten as unknown as () => void;
};

// --- DOM Elements ---
const statusEl = $("status");
const transcriptEl = $("transcript");
const micBtn = $("micBtn") as HTMLButtonElement;
const streamBtn = $("streamBtn") as HTMLButtonElement;
const streamLabel = $("streamLabel");
const audioLevelsEl = $("audioLevels");
const miniWidget = $("miniWidget");
const langSel = $("language") as HTMLSelectElement;
const pasteChk = $("autopaste") as HTMLInputElement;
const modelPath = $("modelPath") as HTMLInputElement;
const groqKey = $("groqKey") as HTMLInputElement;
const settingsToggle = $("settingsToggle");
const settingsPanel = $("settings");
const saveBtn = $("saveBtn");

// --- State ---
let recording = false;
let streaming = false;
let current = { auto_paste: false };

// --- Audio level bars ---
const BAR_COUNT = 32;
let levelBars: HTMLElement[] = [];
function initAudioLevels() {
  audioLevelsEl.innerHTML = "";
  for (let i = 0; i < BAR_COUNT; i++) {
    const bar = document.createElement("div");
    bar.className = "bar";
    audioLevelsEl.appendChild(bar);
    levelBars.push(bar);
  }
}
initAudioLevels();

function updateAudioLevels(levels?: number[]) {
  if (!levels) {
    // Reset bars when not recording
    levelBars.forEach((b) => (b.style.height = "4px"));
    return;
  }
  const step = Math.max(1, Math.floor(levels.length / BAR_COUNT));
  for (let i = 0; i < BAR_COUNT; i++) {
    const idx = Math.min(i * step, levels.length - 1);
    const val = Math.abs(levels[idx] || 0);
    const h = Math.max(4, Math.min(24, val * 200));
    levelBars[i].style.height = `${h}px`;
  }
}

// --- Status helpers ---
function getShortcut(): string {
  const isMac = navigator.platform.toUpperCase().indexOf("MAC") >= 0;
  return isMac ? "⌘⇧V" : "Ctrl+Shift+V";
}

function setStatus(text: string, live: boolean, className?: string) {
  const classes = ["status"];
  if (live) classes.push("live");
  if (className) classes.push(className);
  statusEl.textContent = text;
  statusEl.className = classes.join(" ");
}

function setRecording(v: boolean) {
  recording = v;
  micBtn.classList.toggle("active", v);
  micBtn.setAttribute("aria-pressed", String(v));
  miniWidget.classList.toggle("recording-mini", v);
  audioLevelsEl.classList.toggle("visible", v);

  if (v) {
    setStatus("● Recording…", true, "recording-status");
    return;
  }
  if (streaming) {
    setStatus("● Streaming (Groq)…", true, "streaming-status");
    return;
  }
  setStatus(`● Idle — press ${getShortcut()}`, false);
  updateAudioLevels();
}

function setStreaming(v: boolean) {
  streaming = v;
  streamBtn.classList.toggle("active-stream", v);
  streamBtn.setAttribute("aria-pressed", String(v));
  streamLabel.textContent = v ? "Streaming…" : "Stream (Groq)";

  // Update mini widget streaming state
  if (v) {
    // Streaming is active — show streaming-mini class (takes priority over recording-mini)
    miniWidget.classList.add("streaming-mini");
  } else {
    // Streaming stopped — remove streaming-mini class
    miniWidget.classList.remove("streaming-mini");
  }

  // Update status based on both recording and streaming states
  if (v && !recording) {
    setStatus("● Streaming (Groq)…", true, "streaming-status");
  } else if (!v && !recording) {
    setStatus(`● Idle — press ${getShortcut()}`, false);
  } else if (!v && recording) {
    // Streaming stopped while recording was on — fall back to recording status
    setStatus("● Recording…", true, "recording-status");
  } else if (v && recording) {
    // Streaming started while recording was on — show streaming status
    setStatus("● Streaming (Groq)…", true, "streaming-status");
  }
}

// ============================================
// LOCAL RECORDING (offline Whisper)
// ============================================

async function toggleLocalRecording() {
  try {
    const state = (await safeInvoke("toggle_recording")) as string | null;
    setRecording(state === "recording");
  } catch (e) {
    console.error("Toggle recording failed:", e);
    setStatus("Error: " + (e instanceof Error ? e.message : String(e)), false);
  }
}

micBtn.addEventListener("click", toggleLocalRecording);

// Mini widget also triggers recording
miniWidget.addEventListener("click", (e) => {
  e.stopPropagation();
  if (streaming) {
    toggleStreamingMode();
  } else {
    toggleLocalRecording();
  }
});

// ============================================
// STREAMING MODE (Groq API)
// ============================================

async function toggleStreamingMode() {
  if (streaming) {
    await stopStreamingMode();
  } else {
    await startStreamingMode();
  }
}

async function startStreamingMode() {
  try {
    await safeInvoke("start_streaming");
    setStreaming(true);

    // Start microphone capture and send chunks to the streaming engine
    await startMicCaptureForStreaming();
  } catch (e: any) {
    console.error("Streaming start failed:", e);
    setStatus("Streaming error: " + (e instanceof Error ? e.message : String(e)), false);
    setStreaming(false);
  }
}

async function stopStreamingMode() {
  try {
    if (streamMediaRecorder) {
      streamMediaRecorder.stop();
      streamMediaRecorder = null;
    }
    if (streamMediaStream) {
      streamMediaStream.getTracks().forEach((t) => t.stop());
      streamMediaStream = null;
    }
    await safeInvoke("stop_streaming");
    setStreaming(false);
    setStatus("● Idle — press ⌘⇧V", false);
    updateAudioLevels();
  } catch (e) {
    console.error("Streaming stop failed:", e);
  }
}

streamBtn.addEventListener("click", toggleStreamingMode);

// ============================================
// WEB AUDIO → Tauri streaming pipeline
// ============================================

let streamMediaRecorder: MediaRecorder | null = null;
let streamMediaStream: MediaStream | null = null;
let streamAudioContext: AudioContext | null = null;
let streamAnalyser: AnalyserNode | null = null;

async function startMicCaptureForStreaming() {
  try {
    const stream = await navigator.mediaDevices.getUserMedia({
      audio: {
        sampleRate: 16000,
        channelCount: 1,
        echoCancellation: true,
        noiseSuppression: true,
      },
    });

    streamMediaStream = stream;
    streamAudioContext = new AudioContext({ sampleRate: 16000 });
    const source = streamAudioContext.createMediaStreamSource(stream);
    streamAnalyser = streamAudioContext.createAnalyser();
    streamAnalyser.fftSize = 128;
    source.connect(streamAnalyser);

    // Use ScriptProcessorNode to capture raw PCM and send to Rust
    const bufferSize = 4096;
    const processor = streamAudioContext.createScriptProcessor(bufferSize, 1, 1);

    processor.onaudioprocess = (event) => {
      if (!streaming) return;
      const inputData = event.inputBuffer.getChannelData(0);
      // Convert Float32Array to regular array for Tauri
      const samples = Array.from(inputData);
      safeInvoke("send_audio_chunk", { samples }).catch((e) => {
        console.error("Send audio chunk failed:", e);
      });
    };

    // Note: do NOT connect processor to destination — that would route mic to
    // speakers and cause feedback. The source->processor connection alone is
    // enough to drive onaudioprocess in modern browsers.
    source.connect(processor);

    // Start audio level visualization
    visualizeStreamingLevels();
  } catch (e: any) {
    console.error("Mic capture failed:", e);
    setStatus("Mic error: " + (e instanceof Error ? e.message : String(e)), false);
    setStreaming(false);
  }
}

function visualizeStreamingLevels() {
  if (!streamAnalyser || !streaming) return;

  const dataArray = new Uint8Array(streamAnalyser.frequencyBinCount);

  function draw() {
    if (!streaming || !streamAnalyser) return;
    streamAnalyser.getByteFrequencyData(dataArray);
    const levels = Array.from(dataArray).map((v) => v / 255);
    updateAudioLevels(levels);
    requestAnimationFrame(draw);
  }
  draw();
}

// ============================================
// EVENT LISTENERS from Rust backend
// ============================================

// Local whisper events
safeListen("state-change", (e: any) => setRecording(e.payload === "recording"));

safeListen("transcript", (e: any) => {
  const text = e.payload as string;
  addTranscript(text, true);
});

safeListen("error", (e: any) => {
  addTranscript("Error: " + e.payload, false, true);
});

safeListen("whisperflow-transcript", (e: any) => {
  const chunk = e.payload as {
    text: string;
    is_final: boolean;
    offset_seconds: number;
    duration_seconds: number;
  };

  if (chunk.text && chunk.text.trim()) {
    // Auto-edit the transcript
    safeInvoke<string>("edit_transcript", { text: chunk.text }).then((edited) => {
      const finalText = edited ?? chunk.text;
      addTranscript(finalText, chunk.is_final, false, !chunk.is_final);

      // Auto-paste final transcripts
      if (chunk.is_final && current.auto_paste) {
        navigator.clipboard?.writeText(finalText).catch(() => {});
      }
    });
  }
});

safeListen("whisperflow-status", (e: any) => {
  if (streaming) {
    setStatus("● Listening…", true, "streaming-status");
  }
});

safeListen("whisperflow-error", (e: any) => {
  console.error("WhisperFlow error:", e.payload);
  addTranscript("Streaming error: " + e.payload, false, true);
});

// ============================================
// TRANSCRIPT DISPLAY
// ============================================

function addTranscript(
  text: string,
  isFinal: boolean,
  isError = false,
  isPartial = false
) {
  // Remove any existing partial transcript
  if (isPartial) {
    const existingPartial = transcriptEl.querySelector(".partial");
    if (existingPartial) existingPartial.remove();
  }

  const p = document.createElement("p");
  p.textContent = text;

  if (isError) {
    p.className = "err";
  } else if (isPartial) {
    p.className = "partial";
  } else {
    // Final transcript — add a subtle animation
    p.className = "final";
    p.style.animation = "fadeIn 0.3s ease";
  }

  transcriptEl.appendChild(p);

  // Cap transcript length to avoid unbounded memory growth in long sessions
  while (transcriptEl.children.length > 200) {
    transcriptEl.removeChild(transcriptEl.firstElementChild!);
  }
  transcriptEl.setAttribute(
    "data-empty",
    transcriptEl.children.length === 0 ? "true" : "false"
  );
  transcriptEl.scrollTop = transcriptEl.scrollHeight;

  // Auto-paste for local mode
  if (isFinal && !isError && current.auto_paste && !streaming) {
    navigator.clipboard?.writeText(text).catch(() => {});
  }
}

// ============================================
// SETTINGS
// ============================================

settingsToggle.addEventListener("click", () => {
  const open = settingsPanel.hidden;
  settingsPanel.hidden = !open;
  settingsToggle.setAttribute("aria-expanded", String(open));
});

pasteChk.addEventListener("change", () => {
  pasteChk.setAttribute("aria-checked", String(pasteChk.checked));
});

// Prefill the Groq API key from the persisted WhisperFlow config on startup.
let whisperflowReady: Promise<void> | null = null;
function ensureWhisperflowReady(): Promise<void> {
  if (!whisperflowReady) {
    whisperflowReady = loadWhisperflowConfig();
  }
  return whisperflowReady;
}
async function loadWhisperflowConfig() {
  try {
    const cfg = (await safeInvoke("get_whisperflow_config")) as {
      api_key?: string;
      model?: string;
    };
    if (cfg?.api_key) {
      groqKey.value = cfg.api_key;
    }
  } catch (e) {
    console.error("Failed to load WhisperFlow config:", e);
  }
}

saveBtn.addEventListener("click", async () => {
  await ensureWhisperflowReady();
  await safeInvoke("update_config", {
    cfg: {
      language: langSel.value,
      model_path: modelPath.value,
      auto_paste: pasteChk.checked,
    },
  });
  // Persist the Groq API key via the WhisperFlow config. Keep the rest of the
  // existing WhisperFlow settings untouched by spreading the current config.
  try {
    await safeInvoke("update_whisperflow_config", {
      config: {
        ...(await getCurrentWhisperflowConfig()),
        api_key: groqKey.value.trim(),
      },
    });
  } catch (e) {
    console.error("Failed to save Groq API key:", e);
    setStatus("● Failed to save API key", false);
  }
  current.auto_paste = pasteChk.checked;
  settingsPanel.hidden = true;
});

let cachedWhisperflowConfig: Record<string, unknown> | null = null;
async function getCurrentWhisperflowConfig(): Promise<Record<string, unknown>> {
  if (!cachedWhisperflowConfig) {
    cachedWhisperflowConfig = (await safeInvoke("get_whisperflow_config")) as Record<
      string,
      unknown
    >;
  }
  return cachedWhisperflowConfig;
}

// Load the saved config at startup.
ensureWhisperflowReady();

// ============================================
// KEYBOARD SHORTCUT + TRAY EVENTS
// ============================================

// Listen for streaming toggle from system tray
safeListen("toggle-streaming", () => {
  toggleStreamingMode();
});

document.addEventListener("keydown", (e) => {
  // Space bar to toggle recording (when not in input/button/link)
  const target = e.target as HTMLElement | null;
  const onInteractive = !!target?.closest(
    'button, a, [role="button"], select, [tabindex]:not([tabindex="-1"])'
  );
  if (
    e.code === "Space" &&
    !(target instanceof HTMLInputElement) &&
    !(target instanceof HTMLTextAreaElement) &&
    !onInteractive
  ) {
    e.preventDefault();
    if (streaming) {
      toggleStreamingMode();
    } else {
      toggleLocalRecording();
    }
  }
});

// ============================================
// CSS animation helper
// ============================================
const style = document.createElement("style");
style.textContent = `
@keyframes fadeIn {
  from { opacity: 0; transform: translateY(4px); }
  to { opacity: 1; transform: translateY(0); }
}
`;
document.head.appendChild(style);

// ============================================
// First-launch hint pulse on the mic button
// ============================================
function maybeShowMicHint() {
  if (transcriptEl.children.length === 0 && !recording && !streaming) {
    micBtn.classList.add("pulse-hint");
  }
}
setTimeout(maybeShowMicHint, 1500);

// ============================================
// Global error boundary — non-intrusive banner
// ============================================
function showErrorBanner(msg: string) {
  let banner = document.getElementById("errorBanner");
  if (!banner) {
    banner = document.createElement("div");
    banner.id = "errorBanner";
    banner.className = "error-banner";
    banner.setAttribute("role", "alert");
    const msgEl = document.createElement("span");
    msgEl.className = "error-banner-msg";
    const dismiss = document.createElement("button");
    dismiss.className = "error-banner-dismiss";
    dismiss.setAttribute("aria-label", "Dismiss");
    dismiss.type = "button";
    dismiss.textContent = "×";
    dismiss.addEventListener("click", () => banner!.remove());
    banner.appendChild(msgEl);
    banner.appendChild(dismiss);
    const app = document.getElementById("app");
    app?.prepend(banner);
  }
  const msgSpan = banner.querySelector(".error-banner-msg");
  if (msgSpan) msgSpan.textContent = msg;
}
window.addEventListener("error", (e) => {
  showErrorBanner(`Runtime error: ${e.message}`);
});
window.addEventListener("unhandledrejection", (e) => {
  const reason =
    e.reason instanceof Error ? e.reason.message : String(e.reason ?? "unknown");
  showErrorBanner(`Promise rejection: ${reason}`);
});
