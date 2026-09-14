import SwiftUI

@MainActor
final class VoiceFlowState: ObservableObject {
    enum Tab: String, CaseIterable {
        case agent = "Voice Agent"
        case website = "Website"
        case embed = "Embed Code"
        case meetings = "Meetings"
    }

    // MARK: Published UI state

    /// Single source of truth for the mic session. Side effects live in the
    /// didSet so every entry point (button, menu bar, ⌘/V shortcut) behaves
    /// identically.
    @Published var isListening = false {
        didSet { handleListeningChanged(from: oldValue) }
    }
    @Published var transcript = ""
    @Published var agentReply = ""
    @Published var status: String = "Idle — tap mic to talk"
    @Published var selectedTab: Tab = .agent

    /// Mirrors SpeechService failures so views observe a single object.
    @Published var serviceError: String?
    @Published var permissionDenied = false

    // MARK: Language (persisted via AppStorage, mirrored as @Published so SwiftUI reacts)

    @AppStorage("voiceflow.language") private var storedLanguage = SpeechService.defaultLanguageCode
    @Published private(set) var selectedLanguage: String

    // MARK: Services / backend

    let speech = SpeechService()

    // Placeholder: swap this with your real LLM backend, e.g. "http://localhost:8000/voice"
    var apiUrl: String = ""

    /// Set while a mid-listening language switch restarts recognition, so the
    /// fresh session doesn't wipe the previous exchange from the transcript card.
    private var suppressNextStartClear = false

    init() {
        // Swift 6: cannot touch the @AppStorage wrapper until self is fully
        // initialized — read the same defaults key directly instead.
        let persisted = UserDefaults.standard.string(forKey: "voiceflow.language")
        selectedLanguage = persisted ?? SpeechService.defaultLanguageCode
        wireSpeechService()
    }

    // MARK: Language API

    var currentLanguage: SpeechLanguage? {
        SpeechService.language(forCode: selectedLanguage)
    }

    var displayLanguage: String {
        currentLanguage?.name ?? selectedLanguage
    }

    /// Binding for pickers; routes every change through setLanguage(_:) so a
    /// switch mid-listening restarts recognition in the new locale.
    var languageSelection: Binding<String> {
        Binding(
            get: { [weak self] in self?.selectedLanguage ?? SpeechService.defaultLanguageCode },
            set: { [weak self] in self?.setLanguage($0) }
        )
    }

    func setLanguage(_ code: String) {
        guard code != selectedLanguage, SpeechService.language(forCode: code) != nil else { return }
        selectedLanguage = code
        storedLanguage = code

        guard isListening else {
            status = "Language: \(displayLanguage)"
            return
        }
        // Restart live recognition in the new language without flushing the
        // half-finished utterance or wiping the transcript card.
        suppressNextStartClear = true
        speech.stopRecording(flushPartial: false)
        isListening = false
        isListening = true
        suppressNextStartClear = false
    }

    // MARK: Conversation control

    func clearConversation() {
        speech.stopRecording(flushPartial: false)
        speech.stopSpeaking()
        isListening = false
        transcript = ""
        agentReply = ""
        serviceError = nil
        permissionDenied = false
        status = "Idle — tap mic to talk"
    }

    // MARK: Mock brain — replace with a real backend when apiUrl is set

    func mockReply(for text: String) -> String {
        let t = text.lowercased()
        if t.contains("hello") || t.contains("hi") {
            return "Hey! I'm your VoiceFlow agent — live inside the macOS app. Wire me to your backend via apiUrl and I'll become fully autonomous."
        }
        if t.contains("website") {
            return "The website lives in /VoiceFlow/Website — it's already built and ready to host me. Open the Website tab to preview it."
        }
        if t.contains("embed") {
            return "To embed me on any site, copy the script from the Embed Code tab. One tag, and I appear anywhere."
        }
        return "You said: \"\(text)\" — (mock reply). Set apiUrl to your agent backend to replace this with a real LLM."
    }

    // MARK: Private wiring

    private func wireSpeechService() {
        speech.onPartialTranscript = { [weak self] text in
            guard let self, self.isListening else { return }
            self.transcript = text
        }
        speech.onFinalTranscript = { [weak self] text in
            self?.handleFinalTranscript(text)
        }
        speech.onError = { [weak self] message, needsPermissionFix in
            guard let self else { return }
            self.serviceError = message
            self.permissionDenied = needsPermissionFix
            if self.isListening { self.isListening = false }
            self.status = message
        }
    }

    private func handleListeningChanged(from previous: Bool) {
        guard previous != isListening else { return }
        if isListening {
            if !suppressNextStartClear {
                transcript = ""
                agentReply = ""
                serviceError = nil
                permissionDenied = false
            }
            status = "Listening (\(displayLanguage))… speak now"
            speech.startRecording(localeIdentifier: selectedLanguage)
        } else {
            if speech.isRecording {
                // Flushes any pending partial as a final transcript → reply + TTS.
                speech.stopRecording()
            }
            if status.hasPrefix("Listening") || status.hasPrefix("Speaking") {
                status = "Idle — tap mic to talk"
            }
        }
    }

    private func handleFinalTranscript(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        transcript = trimmed
        let reply = agentReply(for: trimmed)
        agentReply = reply
        // Close the mic before speaking so TTS output isn't transcribed back.
        if isListening { isListening = false }
        status = "Replied — tap mic to talk"
        speech.speak(reply, localeIdentifier: selectedLanguage)
    }

    private func agentReply(for text: String) -> String {
        // TODO: POST {"text": text} to apiUrl and speak the response instead,
        // once the real agent backend endpoint exists. Until then keep mock mode.
        _ = apiUrl
        return mockReply(for: text)
    }
}
