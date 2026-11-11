# REA Workspace: WhisperFlow Development

Welcome to the **REA (Research, Execute, Assess)** engineering workspace for **WhisperFlow**.

All reverse-engineering analysis, system architectures, lifted code modules, and benchmark assessments for the WhisperFlow pipeline reside exclusively within this directory.

---

## 📂 Directory Structure

```
REA/
├── README.md                          # Workspace entry point and workflow guide
├── PLAN.md                            # Comprehensive end-to-end WhisperFlow execution plan
├── research/                          # Phase 1: Reverse-engineering & audit
│   ├── 01_benchmark_deconstruction.md # Wispr Flow mechanical deconstruction
│   ├── 02_codebase_audit.md           # VoiceFlow (Swift) & tauri-app (Rust) gap analysis
│   └── 03_latency_budget.md           # Sub-500ms pipeline budget and timing models
├── architecture/                      # Phase 2: System design & specifications
│   ├── system_architecture.md         # End-to-end dataflow, state machine & diagrams
│   └── component_interfaces.md        # API contracts, data structs & event interfaces
├── execution/                         # Phase 2: Lifted code modules & reference implementations
│   ├── audio/                         # Ring buffer & low-latency VAD subsystem
│   ├── speech/                        # Dual-engine Whisper dispatcher & streaming chunker
│   ├── cleanup/                       # Tiered regex + LLM post-processing
│   ├── injection/                     # Direct AXUIElement & clipboard text injector
│   └── coordinator/                   # Global hotkey state coordinator
└── assessment/                        # Phase 3: Benchmarks & validation
    ├── benchmarks.md                  # Quality gates, WER targets & acceptance matrix
    └── test_runner.sh                 # End-to-end automated test harness
```

---

## 🔄 The REA Process Lifecycle

1. **[Research](file:///Users/kennethaman/VoiceFlow/REA/research/01_benchmark_deconstruction.md)**: Deep-dive into benchmark dictation apps (Wispr Flow), reverse-engineer their core capabilities (circular audio pre-buffering, zero-latency VAD gating, direct accessibility injection, context-aware prompt cleanup), and evaluate our baseline codebase.
2. **[Architecture](file:///Users/kennethaman/VoiceFlow/REA/architecture/system_architecture.md)**: Establish concrete module boundaries, decoupled event buses, zero-copy data structures, and state machines.
3. **[Execution](file:///Users/kennethaman/VoiceFlow/REA/execution/)**: Implement and lift hardened, production-grade modules for audio capture, transcription, text cleanup, and system-wide injection.
4. **[Assessment](file:///Users/kennethaman/VoiceFlow/REA/assessment/benchmarks.md)**: Validate against strict latency budgets ($p50 < 480\text{ms}$ cloud, $p50 < 750\text{ms}$ local), WER accuracy gates ($<4.5\%$), and 100% clipboard preservation.

---

## 🚀 Quick Navigation

- **Master Plan**: [PLAN.md](file:///Users/kennethaman/VoiceFlow/REA/PLAN.md)
- **Wispr Flow Reverse-Engineering**: [research/01_benchmark_deconstruction.md](file:///Users/kennethaman/VoiceFlow/REA/research/01_benchmark_deconstruction.md)
- **Codebase Audit & Gap Analysis**: [research/02_codebase_audit.md](file:///Users/kennethaman/VoiceFlow/REA/research/02_codebase_audit.md)
- **Latency Budget Spec**: [research/03_latency_budget.md](file:///Users/kennethaman/VoiceFlow/REA/research/03_latency_budget.md)
- **System Architecture**: [architecture/system_architecture.md](file:///Users/kennethaman/VoiceFlow/REA/architecture/system_architecture.md)
- **Component Interfaces**: [architecture/component_interfaces.md](file:///Users/kennethaman/VoiceFlow/REA/architecture/component_interfaces.md)
- **Benchmarks & Acceptance Gates**: [assessment/benchmarks.md](file:///Users/kennethaman/VoiceFlow/REA/assessment/benchmarks.md)
