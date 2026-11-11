# Architecture: WhisperFlow System Architecture

## 1. System Data Flow Diagram

```mermaid
flowchart TD
    subgraph OS_Environment["Operating System Environment"]
        MicHardware["Microphone Hardware\n(CoreAudio / ALSA / WASAPI)"]
        ActiveApp["Active Target App\n(Slack, VS Code, Browser, Notes)"]
        EventTap["Global Event Tap\n(CGEventTap / SetWindowsHookEx)"]
    end

    subgraph WhisperFlow_Core["WhisperFlow Pipeline Core"]
        Coordinator["ShortcutCoordinator\n(State Machine: Idle / Holding / HandsFree / Busy)"]

        subgraph Audio_Subsystem["Audio Subsystem"]
            RingBuf["Circular Pre-Buffer\n(Trailing 500ms 16kHz f32)"]
            ActiveRecorder["Active Session Recorder\n(Accumulates samples)"]
            VAD["Silero VAD / Energy Gate\n(Silence cutoff detection)"]
        end

        subgraph Inference_Subsystem["Inference Subsystem"]
            Dispatcher{"Engine Dispatcher\n(Network & Config Aware)"}
            LocalWhisper["whisper.cpp Engine\n(Metal / CoreML / cuBLAS)"]
            CloudWhisper["Groq Streaming Engine\n(HTTP/2 SSE API)"]
        end

        subgraph Cleanup_Subsystem["Intelligence & Post-Processing"]
            L1Cleaner["Tier-1 Lexical Cleaner\n(Fillers, Repetitions, Numbers)"]
            L2LLM["Tier-2 Context LLM\n(App-Aware Grammar & Style)"]
        end

        subgraph Injection_Subsystem["Text Injection Subsystem"]
            TargetInspector["Frontmost App Inspector\n(PID + Bundle ID + AXSupport)"]
            DirectAX["AXUIElement Setter\n(Direct Text Replacement)"]
            ClipboardFallback["Safe Clipboard Swapper\n(Snapshot -> Paste -> Restore)"]
        end

        subgraph Presentation_Subsystem["Presentation Subsystem"]
            HUD["Floating Overlay HUD\n(Non-activating Window + Waveform)"]
            Tray["System Menu Bar / Tray Icon"]
        end
    end

    EventTap -->|Key Edge Events| Coordinator
    MicHardware -->|16kHz PCM Stream| RingBuf

    Coordinator -->|Start Capture| ActiveRecorder
    RingBuf -.->|Prepend 500ms pre-roll| ActiveRecorder
    ActiveRecorder -->|Audio Samples| VAD
    ActiveRecorder -->|Audio Level| HUD

    Coordinator -->|Stop Capture| Dispatcher
    VAD -->|Silence Detected| Coordinator
    ActiveRecorder -->|Full Float Buffer| Dispatcher

    Dispatcher -->|Offline Mode| LocalWhisper
    Dispatcher -->|Online Streaming| CloudWhisper

    LocalWhisper -->|Raw Transcript| L1Cleaner
    CloudWhisper -->|Raw Transcript| L1Cleaner
    L1Cleaner --> L2LLM

    L2LLM -->|Polished Text| TargetInspector
    TargetInspector -->|AX Supported| DirectAX
    TargetInspector -->|AX Fallback| ClipboardFallback

    DirectAX -->|Inject Text| ActiveApp
    ClipboardFallback -->|Paste Cmd+V| ActiveApp

    Coordinator -.->|State Transitions| HUD
    Coordinator -.->|State Transitions| Tray
```

---

## 2. Global State Machine

The dictation pipeline is orchestrated by a deterministic finite state machine (FSM):

```mermaid
stateDiagram-v2
    [*] --> Idle

    Idle --> Holding : KeyDown (Option+Space)
    note right of Holding : Pre-roll audio committed.\nActive capture running.\nHUD displays "Listening".

    Holding --> PendingDoubleTap : KeyUp (held < 300ms)
    PendingDoubleTap --> HandsFree : KeyDown within 350ms
    PendingDoubleTap --> Idle : Timeout (350ms elapsed, discarded)

    Holding --> BusyTranscribing : KeyUp (held >= 300ms)
    HandsFree --> BusyTranscribing : KeyDown / Silence Timeout

    Holding --> Idle : Escape Key (Take Aborted)
    HandsFree --> Idle : Escape Key (Take Aborted)

    BusyTranscribing --> Polishing : Raw Transcript Generated
    Polishing --> Injecting : Text Cleaned
    Injecting --> Idle : Injection Complete / Clipboard Restored
```

---

## 3. Core Subsystem Boundaries

### 3.1 Audio Subsystem
- **Responsibility**: Continuous non-blocking capture of microphone input. Maintains a circular ring buffer of the trailing 500ms. On trigger, stitches pre-roll and active stream into a contiguous `[f32]` 16kHz mono buffer. Runs VAD silence evaluation.
- **Threading**: Audio callback runs on real-time audio thread (`AudioQueue` / `cpal` worker). Splicing and normalization dispatched off-thread.

### 3.2 Inference Subsystem
- **Responsibility**: Executes speech recognition using local quantized Whisper models or the Groq streaming API.
- **Threading**: Strictly asynchronous; never blocks the UI or main application thread.

### 3.3 Intelligence Subsystem
- **Responsibility**: Transforms raw transcription output into natural, clean, contextually formatted prose.
- **Layers**:
  - `Tier-1`: Synchronous regex-based filler word and punctuation post-processing ($<2\text{ms}$).
  - `Tier-2`: Context-aware prompt engine adjusting output based on the frontmost application.

### 3.4 Injection Subsystem
- **Responsibility**: Delivering the generated text directly to the focused control in the active app without user intervention.
- **Safety**: Guarantees zero clipboard corruption via atomic clipboard snapshot and restoration.

### 3.5 Presentation Subsystem
- **Responsibility**: Lightweight, non-activating floating HUD window displaying live audio level visualizer and pipeline status.
