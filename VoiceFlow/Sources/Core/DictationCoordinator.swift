import AppKit
import AVFoundation
import Combine
import Foundation

// MARK: - DictationCoordinator
//
// Owns the full dictation pipeline and wires it into AppState:
//
//   hold Control / hands-free → AudioCaptureEngine (16 kHz mono, 400 ms pre-roll)
//   release / silence timeout → SpeechTranscribing (WhisperKit, whisper.cpp fallback)
//                             → TextPostProcessor → TextPaster

@MainActor
final class DictationCoordinator: ObservableObject {

    // MARK: Published

    @Published private(set) var lastRawTranscription: String?
    @Published private(set) var loadedModelID: String?
    var onTranscriptionReady: ((String) -> Void)?
    var onHandsFreeChanged: ((Bool) -> Void)?
    var onHotkeyBindingChange: ((KeyChord) -> Void)?

    // MARK: Pipeline components

    private(set) var audio = AudioCaptureEngine()
    private(set) var modelManager = ModelManager()
    private(set) var speechEngine: (any SpeechTranscribing)?

    // MARK: Dependencies

    private let appState: AppState
    private let settings: AppSettings

    // MARK: Recording session state

    private var tickerTask: Task<Void, Never>?
    private var recordingStartedAt: Date?
    private var loadGeneration = 0

    private final class WeakMainActorRef<Object: AnyObject>: @unchecked Sendable {
        private weak var object: Object?
        init(_ object: Object) {
            self.object = object
        }
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

    func bootstrap() async {
        if speechEngine == nil {
            await reloadSpeechEngine()
        }

        appState.onStartHook = { [weak self] in
            guard let self else { return }
            Task { await self.beginRecording() }
        }
        appState.onStopHook = { [weak self] in
            guard let self else { return }
            Task { await self.finishRecording() }
        }
        appState.onCancelHook = { [weak self] in
            guard let self else { return }
            Task { await self.cancelRecording() }
        }

        try? await armMicrophone()
    }

    func applyHotkey() {
        onHotkeyBindingChange?(settings.hotkeyMode.chord)
    }

    func selectModel(_ modelID: String) async {
        guard !appState.isRecording else { return }
        let choice = SpeechModelCatalog.modelChoice(modelID, keeping: settings.languageCode)
        let resolved = SpeechModelCatalog.whisperKitVariant(settingsName: choice.model, hardwareName: nil)
        settings.modelName = choice.model
        settings.languageCode = choice.language
        if loadedModelID == resolved, speechEngine != nil {
            return
        }
        await reloadSpeechEngine()
    }

    func selectLanguage(_ languageCode: String) async {
        guard !appState.isRecording else { return }
        let choice = SpeechModelCatalog.languageChoice(languageCode, keeping: settings.modelName)
        let modelChanged = choice.model != SpeechModelCatalog.whisperKitVariant(
            settingsName: settings.modelName,
            hardwareName: nil
        )
        settings.modelName = choice.model
        settings.languageCode = choice.language
        if modelChanged {
            await reloadSpeechEngine()
        }
    }

    func reloadSpeechEngine() async {
        guard !appState.isRecording else { return }
        loadGeneration += 1
        let generation = loadGeneration
        let variant = SpeechModelCatalog.whisperKitVariant(
            settingsName: settings.modelName,
            hardwareName: appState.hardwareProfile?.recommendedWhisperModel
        )
        appState.modelStatus = .downloading(0)

        let stateRef = WeakMainActorRef(appState)
        do {
            let engine = try await WhisperKitSpeechEngine.load(variant: variant) { fraction in
                let ref = stateRef
                let token = generation
                Task { @MainActor in
                    guard token == self.loadGeneration else { return }
                    ref.value?.modelStatus = .downloading(min(max(fraction, 0), 1))
                }
            } onWillLoad: {
                let ref = stateRef
                let token = generation
                Task { @MainActor in
                    guard token == self.loadGeneration else { return }
                    ref.value?.modelStatus = .loading
                }
            }
            guard generation == loadGeneration else { return }
            speechEngine = engine
            loadedModelID = variant
            appState.modelStatus = .ready
        } catch {
            let ggmlName = SpeechModelCatalog.ggmlName(for: variant)
            guard let modelURL = await modelManager.ensureModel(ggmlName, appState: appState) else {
                return
            }
            guard generation == loadGeneration else { return }
            do {
                speechEngine = try await WhisperEngine.create(modelPath: modelURL.path)
                loadedModelID = variant
                appState.modelStatus = .ready
            } catch {
                speechEngine = nil
                loadedModelID = nil
                appState.modelStatus = .failed("Could not load model: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Recording

    func beginRecording(handsFree: Bool = false) async {
        if appState.phase == .idle {
            appState.startDictation(handsFree: handsFree)
        }
        guard appState.isRecording, speechEngine != nil, !audio.isCapturingUtterance else { return }

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            guard granted else {
                notePermissionFailure()
                return
            }
        default:
            notePermissionFailure()
            return
        }

        do {
            try await armMicrophone()
            audio.beginUtterance()
        } catch {
            notePermissionFailure()
            return
        }

        recordingStartedAt = Date()
        startTicker()
        onHandsFreeChanged?(appState.isHandsFree)
        if settings.soundFeedbackEnabled {
            NSSound(named: "Tink")?.play()
        }
    }

    private func armMicrophone() async throws {
        let pump = MainActorLevelPump(appState: appState)
        let weakSelf = WeakMainActorRef(self)
        try audio.activateStandby(
            onLevel: { level in
                pump.emit(level)
            },
            onVadEvent: { event in
                Task { @MainActor in
                    weakSelf.value?.handleVadEvent(event)
                }
            },
            silenceTimeoutSeconds: 2.0
        )
    }

    private func notePermissionFailure() {
        PermissionManager.shared.refreshAll()
        appState.phase = .idle
        onHandsFreeChanged?(false)
    }

    public func toggleHandsFree() async {
        if appState.isRecording {
            await finishRecording()
        } else {
            await beginRecording(handsFree: true)
        }
    }

    public func cancelRecording() async {
        tickerTask?.cancel()
        tickerTask = nil
        audio.stopAndReturnSamples()
        recordingStartedAt = nil
        appState.cancelDictation()
        onHandsFreeChanged?(false)
    }

    public func finishRecording(trailingSilenceSeconds: Double = 0.0) async {
        tickerTask?.cancel()
        tickerTask = nil

        let samples = audio.stopAndReturnSamples(truncateSilenceSeconds: trailingSilenceSeconds)
        let duration = recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        recordingStartedAt = nil

        guard DictationGate.shouldTranscribe(
            sampleCount: samples.count,
            holdDuration: duration,
            minimumDuration: settings.minRecordingDuration
        ) else {
            appState.phase = .idle
            onHandsFreeChanged?(false)
            return
        }

        guard let speechEngine else {
            appState.phase = .idle
            onHandsFreeChanged?(false)
            return
        }

        appState.phase = .transcribing
        onHandsFreeChanged?(false)

        do {
            let language = SpeechModelCatalog.isEnglishOnly(loadedModelID ?? settings.modelName)
                ? "en"
                : settings.languageCode
            let rawText = try await speechEngine.transcribe(
                samples: samples,
                languageCode: language == SpeechModelCatalog.automaticLanguage ? nil : language
            )
            let cleaned = TextPostProcessor.process(
                rawText,
                removeFillers: settings.cleanupMode != .none
            )

            lastRawTranscription = rawText
            guard DictationGate.shouldPaste(cleaned) else {
                appState.phase = .idle
                return
            }

            appState.finishTranscription(
                text: cleaned,
                duration: duration,
                saveHistory: settings.historyEnabled
            )
            if settings.soundFeedbackEnabled {
                NSSound(named: "Pop")?.play()
            }

            if settings.autoPasteEnabled {
                onTranscriptionReady?(cleaned)
            }
        } catch {
            lastRawTranscription = nil
            appState.phase = .idle
        }
    }

    private func handleVadEvent(_ event: VadEvent) {
        switch event {
        case .speechStarted:
            appState.resetSilenceCountdown()
        case .silenceCountdown(let remaining, let progress):
            if appState.isHandsFree {
                appState.updateSilenceCountdown(remainingSeconds: remaining, progress: progress)
            }
        case .silenceTimeout(let trailingSilence):
            if appState.isHandsFree {
                appState.resetSilenceCountdown()
                Task { await self.finishRecording(trailingSilenceSeconds: trailingSilence) }
            }
        }
    }

    // MARK: Ticker

    private func startTicker() {
        let startedAt = recordingStartedAt ?? Date()
        tickerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard let self, self.appState.isRecording else { break }
                self.appState.tick(elapsed: Date().timeIntervalSince(startedAt))
            }
        }
    }
}
