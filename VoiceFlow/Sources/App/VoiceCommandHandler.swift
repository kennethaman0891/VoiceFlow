import Foundation

// MARK: - VoiceCommand

enum VoiceCommand: String, CaseIterable {
    case startMeeting = "new meeting"
    case stopMeeting = "stop meeting"
    case stopRecording = "stop recording"
    case saveNotes = "save notes"
    case repeatLast = "what did i say"
    case clearScreen = "clear screen"
    case help = "help"

    var description: String {
        switch self {
        case .startMeeting: return "Start a new meeting recording"
        case .stopMeeting: return "Stop the current meeting"
        case .stopRecording: return "Stop dictation"
        case .saveNotes: return "Generate AI summary"
        case .repeatLast: return "Repeat last transcription"
        case .clearScreen: return "Clear the transcript"
        case .help: return "Show available commands"
        }
    }
}

// MARK: - VoiceCommandParser

/// Parses natural language voice commands.
final class VoiceCommandParser {
    static let shared = VoiceCommandParser()

    private init() {}

    // MARK: - Public API

    /// Parse a transcript and return matching commands.
    func parseCommands(in text: String) -> [VoiceCommand] {
        let lowerText = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        var matched: [VoiceCommand] = []

        for command in VoiceCommand.allCases {
            if lowerText.contains(command.rawValue) {
                matched.append(command)
            }
        }

        return matched
    }

    /// Check if the entire text is a single command.
    func extractCommand(from text: String) -> VoiceCommand? {
        let lowerText = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        for command in VoiceCommand.allCases {
            if lowerText == command.rawValue || lowerText.hasPrefix(command.rawValue + " ") {
                return command
            }
        }

        return nil
    }

    /// Get help text for all commands.
    func helpText() -> String {
        var text = "Available voice commands:\n\n"
        for command in VoiceCommand.allCases {
            text += "- **\"\(command.rawValue)\"**: \(command.description)\n"
        }
        return text
    }
}

// MARK: - VoiceCommandHandler

/// Handles executing voice commands.
@MainActor
final class VoiceCommandHandler {
    static let shared = VoiceCommandHandler()

    private let parser = VoiceCommandParser.shared
    private let meetingManager = MeetingManager.shared
    private let coordinator: DictationCoordinator?

    private init() {}

    // MARK: - Public API

    /// Process a transcript and execute any matching commands.
    func process(_ text: String, coordinator: DictationCoordinator?) {
        self.coordinator = coordinator

        guard let command = parser.extractCommand(from: text) else {
            return // Not a command, just regular speech
        }

        execute(command)
    }

    // MARK: - Private

    private func execute(_ command: VoiceCommand) {
        switch command {
        case .startMeeting:
            Task { await meetingManager.startMeeting() }
        case .stopMeeting:
            Task { await meetingManager.stopMeeting() }
        case .stopRecording:
            Task { await coordinator?.finishRecording() }
        case .saveNotes:
            Task {
                if let session = meetingManager.activeSession {
                    await session.generateSummary()
                }
            }
        case .repeatLast:
            // Repeat last transcript - would need to store history
            break
        case .clearScreen:
            // Clear transcript display
            break
        case .help:
            print(parser.helpText())
        }
    }
}
