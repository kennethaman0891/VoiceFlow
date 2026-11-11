import Foundation
import Combine

// MARK: - Types

public enum DictationPhase: Equatable, Sendable {
    case idle
    case recording
    case handsFree
    case transcribing
    case success
}

public enum ModelStatus: Equatable, Sendable {
    case notDownloaded
    case downloading(Double)   // 0...1
    case loading               // weights are on disk and being brought up
    case ready                 // model file exists on disk
    case failed(String)
}

public struct TranscriptionEntry: Codable, Identifiable, Sendable {
    public let id: UUID
    public let text: String
    public let date: Date
    public let duration: TimeInterval

    public init(id: UUID = UUID(), text: String, date: Date, duration: TimeInterval) {
        self.id = id
        self.text = text
        self.date = date
        self.duration = duration
    }
}

// MARK: - AppState

/// Central UI-facing state for VoiceFlow.
@MainActor
public final class AppState: ObservableObject {

    public static let historyStorageKey = "transcriptionHistory"
    public static let historyCap = 100
    public static let audioBarCount = 40

    // MARK: Published state

    @Published public var phase: DictationPhase = .idle
    @Published public var audioLevels: [Float] = Array(repeating: 0, count: AppState.audioBarCount)
    @Published public var elapsedSeconds: TimeInterval = 0
    @Published public var modelStatus: ModelStatus = .notDownloaded
    @Published public var lastTranscription: String?
    @Published public var liveTranscript: String = ""
    @Published public var transcriptionHistory: [TranscriptionEntry] = []
    @Published public var hardwareProfile: HardwareProfile?
    @Published public var silenceProgress: Double = 0.0
    @Published public var silenceRemainingSeconds: Double = 0.0
    @Published public var isSilenceCountingDown: Bool = false

    // MARK: Pipeline hooks

    public var onStartHook: (() -> Void)?
    public var onStopHook: (() -> Void)?
    public var onCancelHook: (() -> Void)?

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.hardwareProfile = HardwareProfiler.profile()
        loadHistory()
    }

    // MARK: Computed

    public var isRecording: Bool {
        phase == .recording || phase == .handsFree
    }

    public var isHandsFree: Bool {
        phase == .handsFree
    }

    public var menuBarIcon: String {
        switch phase {
        case .idle: return "mic.circle"
        case .recording: return "waveform"
        case .handsFree: return "waveform.badge.magnifyingglass"
        case .transcribing: return "ellipsis.circle"
        case .success: return "checkmark.circle.fill"
        }
    }

    public var modelStatusDescription: String {
        switch modelStatus {
        case .notDownloaded:
            return "Whisper model not downloaded"
        case .downloading(let progress):
            return "Downloading speech model… \(Int(progress * 100))%"
        case .loading:
            return "Loading speech model…"
        case .ready:
            return "Speech model ready"
        case .failed(let message):
            return "Model failed: \(message)"
        }
    }

    public var isReadyToDictate: Bool {
        if case .ready = modelStatus { return true }
        return false
    }

    // MARK: Dictation lifecycle

    public func startDictation(handsFree: Bool = false) {
        guard phase == .idle else { return }
        phase = handsFree ? .handsFree : .recording
        elapsedSeconds = 0
        liveTranscript = ""
        isSilenceCountingDown = false
        silenceProgress = 0.0
        audioLevels = Array(repeating: 0, count: AppState.audioBarCount)
        onStartHook?()
    }

    public func stopDictation() {
        guard isRecording else { return }
        phase = .transcribing
        isSilenceCountingDown = false
        onStopHook?()
    }

    public func cancelDictation() {
        guard isRecording || phase == .transcribing else { return }
        phase = .idle
        liveTranscript = ""
        isSilenceCountingDown = false
        silenceProgress = 0.0
        onCancelHook?()
    }

    // MARK: Pipeline inputs

    public func updateAudioLevel(_ level: Float) {
        let clamped = min(max(level, 0), 1)
        audioLevels.append(clamped)
        if audioLevels.count > AppState.audioBarCount {
            audioLevels.removeFirst(audioLevels.count - AppState.audioBarCount)
        }
    }

    public func updateSilenceCountdown(remainingSeconds: Double, progress: Double) {
        isSilenceCountingDown = true
        silenceRemainingSeconds = remainingSeconds
        silenceProgress = progress
    }

    public func resetSilenceCountdown() {
        isSilenceCountingDown = false
        silenceProgress = 0.0
        silenceRemainingSeconds = 0.0
    }

    public func tick(elapsed: TimeInterval) {
        elapsedSeconds = elapsed
    }

    public func finishTranscription(text: String, duration: TimeInterval, saveHistory: Bool = true) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            lastTranscription = trimmed
            liveTranscript = trimmed
            if saveHistory {
                let entry = TranscriptionEntry(text: trimmed, date: Date(), duration: duration)
                transcriptionHistory.insert(entry, at: 0)
                if transcriptionHistory.count > AppState.historyCap {
                    transcriptionHistory.removeLast(transcriptionHistory.count - AppState.historyCap)
                }
                persistHistory()
            }
        }
        phase = .success
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            if self.phase == .success {
                self.phase = .idle
            }
        }
    }

    // MARK: History persistence

    public func clearHistory() {
        transcriptionHistory.removeAll()
        defaults.removeObject(forKey: Self.historyStorageKey)
    }

    public func loadHistory() {
        guard let data = defaults.data(forKey: Self.historyStorageKey) else { return }
        do {
            transcriptionHistory = try JSONDecoder().decode([TranscriptionEntry].self, from: data)
        } catch {
            transcriptionHistory = []
        }
    }

    private func persistHistory() {
        do {
            let data = try JSONEncoder().encode(transcriptionHistory)
            defaults.set(data, forKey: Self.historyStorageKey)
        } catch {
            // Persistence is best-effort
        }
    }
}
