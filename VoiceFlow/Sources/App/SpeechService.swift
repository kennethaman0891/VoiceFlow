//
//  SpeechService.swift
//  VoiceFlow
//
//  Live speech-to-text (SFSpeechRecognizer + AVAudioEngine) and text-to-speech
//  (AVSpeechSynthesizer) behind a single @MainActor service.
//
//  Swift 6 concurrency notes:
//  - The whole service is @MainActor, so all published state is touched on main.
//  - The audio tap closure runs on a private queue; it only captures a Sendable
//    box around the recognition request — never MainActor state.
//  - Recognition results arrive off-main and hop back via `Task { @MainActor … }`.
//

import AVFoundation
import Foundation
import Speech

// MARK: - Language catalog (single source of truth for STT + TTS)

struct SpeechLanguage: Identifiable, Hashable {
    let code: String   // BCP-47 identifier, e.g. "pt-BR"
    let name: String   // Human-readable display name
    let flag: String   // Emoji flag for the UI
    var id: String { code }
}

// MARK: - Sendable bridge for the recognition request
//
// `SFSpeechAudioBufferRecognitionRequest.append(_:)` is designed to be called
// from the audio tap queue, but the class carries no Sendable annotation in the
// SDK. This minimal box lets the @Sendable tap closure capture it without
// marking anything else unchecked.

private final class RecognitionRequestBox: @unchecked Sendable {
    let request: SFSpeechAudioBufferRecognitionRequest
    init(request: SFSpeechAudioBufferRecognitionRequest) {
        self.request = request
    }
}

// MARK: - SpeechService

// AVSpeechSynthesizerDelegate refines NSObjectProtocol, so the service
// inherits NSObject; all witnesses are nonisolated and hop to the main actor.

@MainActor
final class SpeechService: NSObject, ObservableObject {

    // MARK: Shared language catalog

    static let languages: [SpeechLanguage] = [
        SpeechLanguage(code: "en-US", name: "English (US)", flag: "🇺🇸"),
        SpeechLanguage(code: "en-GB", name: "English (UK)", flag: "🇬🇧"),
        SpeechLanguage(code: "es-ES", name: "Español (España)", flag: "🇪🇸"),
        SpeechLanguage(code: "es-MX", name: "Español (México)", flag: "🇲🇽"),
        SpeechLanguage(code: "fr-FR", name: "Français", flag: "🇫🇷"),
        SpeechLanguage(code: "de-DE", name: "Deutsch", flag: "🇩🇪"),
        SpeechLanguage(code: "it-IT", name: "Italiano", flag: "🇮🇹"),
        SpeechLanguage(code: "pt-BR", name: "Português (Brasil)", flag: "🇧🇷"),
        SpeechLanguage(code: "nl-NL", name: "Nederlands", flag: "🇳🇱"),
        SpeechLanguage(code: "hi-IN", name: "हिन्दी", flag: "🇮🇳"),
        SpeechLanguage(code: "ar-SA", name: "العربية", flag: "🇸🇦"),
        SpeechLanguage(code: "zh-CN", name: "中文 (简体)", flag: "🇨🇳"),
        SpeechLanguage(code: "ja-JP", name: "日本語", flag: "🇯🇵"),
        SpeechLanguage(code: "ko-KR", name: "한국어", flag: "🇰🇷"),
        SpeechLanguage(code: "ru-RU", name: "Русский", flag: "🇷🇺"),
        SpeechLanguage(code: "tr-TR", name: "Türkçe", flag: "🇹🇷")
    ]

    static let defaultLanguageCode = "en-US"

    static func language(forCode code: String) -> SpeechLanguage? {
        languages.first { $0.code == code }
    }

    // MARK: Published state

    @Published private(set) var isRecording = false
    @Published private(set) var partialTranscript = ""
    @Published private(set) var errorMessage: String?
    @Published private(set) var permissionDenied = false
    /// Cheap per-locale capability probe, refreshed at session start.
    @Published private(set) var onDeviceRecognitionSupported = false
    @Published private(set) var isSpeaking = false

    // MARK: Callbacks (all invoked on the main actor)

    /// A finalized utterance (natural pause, end-of-speech, or manual stop).
    var onFinalTranscript: ((String) -> Void)?
    /// Live partial results while the user is talking.
    var onPartialTranscript: ((String) -> Void)?
    /// Recoverable failure. The Bool hints whether the fix lives in System Settings.
    var onError: ((String, Bool) -> Void)?

    /// When `false` (default) recognition ends after the first finalized
    /// utterance, so the agent reply can be spoken without the microphone
    /// transcribing VoiceFlow's own TTS output.
    var continuousMode = false

    // MARK: Private pipeline

    private let synthesizer = AVSpeechSynthesizer()
    // `nonisolated(unsafe)`: touched from the nonisolated deinit as a
    // last-resort teardown (thread-safe ObjC calls only).
    nonisolated(unsafe) private var audioEngine: AVAudioEngine?
    nonisolated(unsafe) private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    nonisolated(unsafe) private var recognitionTask: SFSpeechRecognitionTask?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    deinit {
        // Last-resort teardown if the service is destroyed mid-session.
        // These are thread-safe ObjC calls; no MainActor state is mutated here.
        audioEngine?.stop()
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
    }

    // MARK: Recording lifecycle

    /// Starts live recognition in the given BCP-47 locale. Permissions are
    /// requested lazily on first use; safe to call repeatedly.
    func startRecording(localeIdentifier: String) {
        guard !isRecording else { return }
        errorMessage = nil
        permissionDenied = false
        partialTranscript = ""
        Task { await beginRecording(localeIdentifier: localeIdentifier) }
    }

    /// Stops recognition. With `flushPartial` true and the user mid-sentence,
    /// the pending partial text is delivered as a final transcript so a manual
    /// stop still produces an agent reply.
    func stopRecording(flushPartial: Bool = true) {
        guard isRecording else { return }
        if flushPartial {
            let pending = partialTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            partialTranscript = ""
            if !pending.isEmpty {
                onFinalTranscript?(pending)
            }
        } else {
            partialTranscript = ""
        }
        teardownAudioPipeline()
        isRecording = false
    }

    private func beginRecording(localeIdentifier: String) async {
        // 1. Permissions: speech recognition first, then microphone.
        guard await ensurePermissions() else { return }

        // 2. Recognizer availability for this locale.
        let locale = Locale(identifier: localeIdentifier)
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            let name = Self.language(forCode: localeIdentifier)?.name ?? localeIdentifier
            fail("Speech recognition isn't available for \(name). Pick another language.")
            return
        }
        onDeviceRecognitionSupported = recognizer.supportsOnDeviceRecognition
        guard recognizer.isAvailable else {
            fail("Speech recognition is unavailable right now (offline?). Try again shortly.")
            return
        }

        // NOTE: no AVAudioSession configuration here — it's iOS-only. On macOS
        // the input engine captures the default microphone directly once the
        // AVCaptureDevice microphone permission is granted.

        // 4. Engine + recognition request.
        let engine = AVAudioEngine()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            fail("No microphone input detected. Connect or enable a mic and try again.")
            return
        }

        audioEngine = engine
        recognitionRequest = request

        // Tap: touches only the Sendable box — no MainActor state from the
        // audio callback. (Current SDK signature has no queue parameter.)
        let box = RecognitionRequestBox(request: request)
        inputNode.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [box] buffer, _ in
            box.request.append(buffer)
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            audioEngine = nil
            recognitionRequest = nil
            fail("Couldn't start the microphone engine: \(error.localizedDescription)")
            return
        }

        // 5. Recognition task. Results arrive off-main; hop to the main actor.
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let best = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            Task { @MainActor [weak self] in
                self?.consume(transcript: best, isFinal: isFinal, error: error)
            }
        }

        isRecording = true
    }

    private func consume(transcript: String?, isFinal: Bool, error: (any Error)?) {
        if let error {
            // Errors arriving after a deliberate stop are teardown noise.
            guard isRecording else { return }
            teardownAudioPipeline()
            isRecording = false
            fail("Speech recognition failed: \(error.localizedDescription)")
            return
        }
        guard let transcript, !transcript.isEmpty else { return }
        if isFinal {
            let finalText = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            partialTranscript = ""
            guard !finalText.isEmpty else { return }
            onFinalTranscript?(finalText)
            if !continuousMode, isRecording {
                // One utterance per session by default (see `continuousMode`).
                teardownAudioPipeline()
                isRecording = false
            }
        } else {
            partialTranscript = transcript
            onPartialTranscript?(transcript)
        }
    }

    private func teardownAudioPipeline() {
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            if engine.isRunning {
                engine.stop()
            }
        }
        audioEngine = nil

        recognitionRequest?.endAudio()
        recognitionRequest = nil

        recognitionTask?.cancel()
        recognitionTask = nil
    }

    // MARK: Permissions

    private func ensurePermissions() async -> Bool {
        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard speechStatus == .authorized else {
            permissionDenied = true
            if speechStatus == .notDetermined {
                fail("Speech recognition authorization didn't complete — try again.")
            } else {
                fail("Speech recognition is disabled for VoiceFlow. Enable it in System Settings › Privacy & Security › Speech Recognition.",
                     permissionIssue: true)
            }
            return false
        }

        // Microphone access (the AVAudioSession record prompt is iOS-only;
        // macOS gates mic capture through AVCaptureDevice).
        let micGranted = await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { continuation.resume(returning: $0) }
        }
        guard micGranted else {
            permissionDenied = true
            fail("Microphone access is denied. Enable VoiceFlow in System Settings › Privacy & Security › Microphone.",
                 permissionIssue: true)
            return false
        }
        return true
    }

    private func fail(_ message: String, permissionIssue: Bool = false) {
        errorMessage = message
        onError?(message, permissionIssue)
    }

    // MARK: Text-to-speech

    /// Speaks `text` using the best installed voice for `localeIdentifier`.
    func speak(_ text: String, localeIdentifier: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        stopSpeaking()

        let utterance = AVSpeechUtterance(string: trimmed)
        // Best installed voice for the requested locale; when none matches,
        // leave voice unset and the system default renders the utterance.
        if let voice = AVSpeechSynthesisVoice(language: localeIdentifier) {
            utterance.voice = voice
        }
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.postUtteranceDelay = 0.1

        isSpeaking = true
        synthesizer.speak(utterance)
    }

    func stopSpeaking() {
        guard synthesizer.isSpeaking || synthesizer.isPaused else { return }
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }
}

// MARK: - TTS delegate (nonisolated witnesses that hop to the main actor)

extension SpeechService: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = true }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false }
    }
}
