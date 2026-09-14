import AVFoundation
import Combine
import Foundation

// MARK: - DictationCoordinator
//
// Owns the full dictation pipeline and wires it into AppState:
//
//   hold-to-talk start → AudioCaptureEngine (16 kHz mono + level metering)
//   release            → WhisperEngine (English transcription, off-main)
//                      → TextPostProcessor → AppState.finishTranscription
//
// MainActor-isolated: every UI-facing mutation happens here; heavy work is
// pushed down into the audio engine's queues and WhisperEngine's serial queue.

@MainActor
final class DictationCoordinator: ObservableObject {

    // MARK: Published

    /// Raw whisper output before post-processing (useful for debugging/Settings).
    @Published private(set) var lastRawTranscription: String?

    /// Set by the text-injection task to paste finished transcripts into the
    /// frontmost app when `settings.autoPasteEnabled` is on.
    var onTranscriptionReady: ((String) -> Void)?

    // MARK: Pipeline components

    private(set) var audio = AudioCaptureEngine()
    private(set) var modelManager = ModelManager()
    private(set) var engine: WhisperEngine?

    // MARK: Dependencies

    private let appState: AppState
    private let settings: AppSettings

    // MARK: Recording session state

    private var tickerTask: Task<Void, Never>?
    private var recordingStartedAt: Date?

    /// Minimum samples at 16 kHz below which a recording counts as silence.
    private let minimumSampleCount = 4800

    /// Bridges audio-queue levels to the main actor without violating strict
    /// concurrency: the engine's tap requires a `@Sendable` handler, so only a
    /// `@unchecked Sendable` weak-reference box crosses that boundary; the
    /// MainActor-isolated AppState is unwrapped *inside* the main-actor task.
    private final class WeakMainActorRef<Object: AnyObject>: @unchecked Sendable {
        private weak var object: Object?
        init(_ object: Object) {
            self.object = object
        }

        /// Read from the main actor.
        var value: Object? { object }
    }

    private struct MainActorLevelPump: @unchecked Sendable {
        private let ref: WeakMainActorRef<AppState>

        init(appState: AppState) {
            ref = WeakMainActorRef(appState)
        }

        func emit(_ level: Float) {
            let box = ref
            Task { @MainActor in
                box.value?.updateAudioLevel(level)
            }
        }
    }

    init(appState: AppState, settings: AppSettings) {
        self.appState = appState
        self.settings = settings
    }

    // MARK: Bootstrap

    /// Ensures the model exists locally, creates the engine, and hooks the
    /// AppState start/stop events. Idempotent; safe to call from `.task`.
    func bootstrap() async {
        guard engine == nil else { return }

        guard let modelURL = await modelManager.ensureModel(settings.modelName, appState: appState) else {
            return // appState.modelStatus already carries the failure reason
        }

        do {
            // Model loading is heavy — performed off the main thread inside create().
            engine = try await WhisperEngine.create(modelPath: modelURL.path)
        } catch {
            appState.modelStatus = .failed("Could not load model: \(error.localizedDescription)")
            return
        }

        appState.onStartHook = { [weak self] in
            guard let self else { return }
            Task { await self.beginRecording() }
        }
        appState.onStopHook = { [weak self] in
            guard let self else { return }
            Task { await self.finishRecording() }
        }
    }

    // MARK: Recording

    func beginRecording() async {
        guard appState.phase == .recording, engine != nil, !audio.isRunning else { return }

        // Microphone permission.
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            guard granted else {
                PermissionManager.shared.refreshAll()
                appState.phase = .idle
                return
            }
        default:
            PermissionManager.shared.refreshAll()
            appState.phase = .idle
            return
        }

        do {
            let pump = MainActorLevelPump(appState: appState)
            try audio.start(onLevel: { level in
                pump.emit(level)
            })
        } catch {
            PermissionManager.shared.refreshAll()
            appState.phase = .idle
            return
        }

        recordingStartedAt = Date()
        startTicker()
    }

    func finishRecording() async {
        tickerTask?.cancel()
        tickerTask = nil

        let samples = audio.stopAndReturnSamples()
        let duration = recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        recordingStartedAt = nil

        // Accidental taps / pure silence: skip transcription entirely.
        guard duration >= settings.minRecordingDuration,
              samples.count >= minimumSampleCount else {
            appState.phase = .idle
            return
        }

        guard let engine else {
            appState.phase = .idle
            return
        }

        do {
            // Transcription runs on WhisperEngine's background serial queue;
            // we simply await the result here on the main actor.
            let rawText = try await engine.transcribe(samples: samples)
            let cleaned = TextPostProcessor.process(rawText)

            lastRawTranscription = rawText
            appState.finishTranscription(text: cleaned, duration: duration)

            if settings.autoPasteEnabled, !cleaned.isEmpty {
                onTranscriptionReady?(cleaned)
            }
        } catch {
            // Reset UI without recording a failed attempt as history.
            lastRawTranscription = nil
            appState.finishTranscription(text: "", duration: duration)
        }
    }

    // MARK: Ticker

    /// 10 Hz elapsed-time updates for the recording UI. Runs as a main-actor
    /// task so no run-loop/timer threading subtleties apply.
    private func startTicker() {
        let startedAt = recordingStartedAt ?? Date()
        tickerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard let self, self.appState.phase == .recording else { break }
                self.appState.tick(elapsed: Date().timeIntervalSince(startedAt))
            }
        }
    }
}
