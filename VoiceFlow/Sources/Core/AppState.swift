import Foundation
import Combine

// MARK: - Types

enum DictationPhase {
    case idle
    case recording
    case transcribing
}

enum ModelStatus: Equatable {
    case notDownloaded
    case downloading(Double)   // 0...1
    case ready                 // model file exists on disk
    case failed(String)
}

struct TranscriptionEntry: Codable, Identifiable {
    let id: UUID
    let text: String
    let date: Date
    let duration: TimeInterval

    init(id: UUID = UUID(), text: String, date: Date, duration: TimeInterval) {
        self.id = id
        self.text = text
        self.date = date
        self.duration = duration
    }
}

// MARK: - AppState

/// Central UI-facing state for VoiceFlow.
///
/// The dictation pipeline task (audio capture + Whisper engine) wires itself up
/// by assigning `onStartHook` / `onStopHook` and driving `updateAudioLevel`,
/// `tick(elapsed:)` and `finishTranscription(text:duration:)`.
@MainActor
final class AppState: ObservableObject {

    static let historyStorageKey = "transcriptionHistory"
    static let historyCap = 100
    static let audioBarCount = 40

    // MARK: Published state

    @Published var phase: DictationPhase = .idle
    @Published var audioLevels: [Float] = Array(repeating: 0, count: AppState.audioBarCount)
    @Published var elapsedSeconds: TimeInterval = 0
    @Published var modelStatus: ModelStatus = .notDownloaded
    @Published var lastTranscription: String?
    @Published var transcriptionHistory: [TranscriptionEntry] = []

    // MARK: Pipeline hooks (wired by the dictation-pipeline task)

    /// Fired when a dictation session starts (recording begins).
    var onStartHook: (() -> Void)?

    /// Fired when the user stops recording; the pipeline should transcribe and
    /// then call `finishTranscription(text:duration:)`.
    var onStopHook: (() -> Void)?

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        loadHistory()
    }

    // MARK: Computed

    var menuBarIcon: String {
        switch phase {
        case .idle: return "mic.circle"
        case .recording: return "waveform"
        case .transcribing: return "ellipsis.circle"
        }
    }

    var modelStatusDescription: String {
        switch modelStatus {
        case .notDownloaded:
            return "Whisper model not downloaded"
        case .downloading(let progress):
            return "Downloading model… \(Int(progress * 100))%"
        case .ready:
            return "Whisper model ready"
        case .failed(let message):
            return "Model failed: \(message)"
        }
    }

    var isReadyToDictate: Bool {
        if case .ready = modelStatus { return true }
        return false
    }

    // MARK: Dictation lifecycle

    func startDictation() {
        guard phase == .idle else { return }
        phase = .recording
        elapsedSeconds = 0
        audioLevels = Array(repeating: 0, count: AppState.audioBarCount)
        onStartHook?()
    }

    func stopDictation() {
        guard phase == .recording else { return }
        phase = .transcribing
        onStopHook?()
    }

    // MARK: Pipeline inputs

    /// Pushes a new waveform level (0...1); keeps a ring of `audioBarCount` bars.
    func updateAudioLevel(_ level: Float) {
        let clamped = min(max(level, 0), 1)
        audioLevels.append(clamped)
        if audioLevels.count > AppState.audioBarCount {
            audioLevels.removeFirst(audioLevels.count - AppState.audioBarCount)
        }
    }

    /// Updates the elapsed recording time.
    func tick(elapsed: TimeInterval) {
        elapsedSeconds = elapsed
    }

    /// Called by the pipeline when transcription completes; returns state to idle.
    func finishTranscription(text: String, duration: TimeInterval) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            lastTranscription = trimmed
            let entry = TranscriptionEntry(text: trimmed, date: Date(), duration: duration)
            transcriptionHistory.insert(entry, at: 0)
            if transcriptionHistory.count > AppState.historyCap {
                transcriptionHistory.removeLast(transcriptionHistory.count - AppState.historyCap)
            }
            persistHistory()
        }
        phase = .idle
    }

    // MARK: History persistence

    func clearHistory() {
        transcriptionHistory.removeAll()
        defaults.removeObject(forKey: Self.historyStorageKey)
    }

    func loadHistory() {
        guard let data = defaults.data(forKey: Self.historyStorageKey) else { return }
        do {
            transcriptionHistory = try JSONDecoder().decode([TranscriptionEntry].self, from: data)
        } catch {
            // Corrupt or incompatible history: start fresh rather than crash.
            transcriptionHistory = []
        }
    }

    private func persistHistory() {
        do {
            let data = try JSONEncoder().encode(transcriptionHistory)
            defaults.set(data, forKey: Self.historyStorageKey)
        } catch {
            // Persistence is best-effort; keep in-memory history regardless.
        }
    }
}
