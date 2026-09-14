import Foundation

// MARK: - MeetingMarkdownWriter

/// Writes meeting transcripts to markdown files.
final class MeetingMarkdownWriter {
    static let shared = MeetingMarkdownWriter()

    private init() {}

    /// Returns the directory where meeting markdown files are stored.
    func meetingsDirectory() -> URL? {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("VoiceFlow")
            .appendingPathComponent("meetings")

        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        return appSupport
    }

    /// Saves a meeting transcript as a markdown file.
    func save(_ transcript: MeetingTranscript) throws -> URL {
        guard let directory = meetingsDirectory() else {
            throw MeetingError.cannotAccessStorage
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let filename = dateFormatter.string(from: transcript.startDate)
            + "-" + sanitizeFilename(transcript.meetingName)
            + ".md"

        let fileURL = directory.appendingPathComponent(filename)
        let content = transcript.formattedOutput

        try content.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    /// Lists all saved meeting transcripts.
    func listMeetings() -> [SavedMeeting] {
        guard let directory = meetingsDirectory() else { return [] }

        do {
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
                .filter { $0.pathExtension == "md" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }

            return files.map { file in
                SavedMeeting(
                    url: file,
                    fileName: file.deletingPathExtension().lastPathComponent,
                    modificationDate: file.modificationDate
                )
            }
        } catch {
            return []
        }
    }

    /// Reads a meeting transcript from disk.
    func load(from url: URL) async throws -> MeetingTranscript {
        let content = try String(contentsOf: url, encoding: .utf8)
        return parse(markdown: content, url: url)
    }

    /// Deletes a meeting transcript.
    func delete(_ url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    // MARK: - Private

    private func sanitizeFilename(_ name: String) -> String {
        let invalidChars = CharacterSet(charactersIn: "/\\:*?\"<>|")
        return name.components(separatedBy: invalidChars).joined(separator: "-")
    }

    private func parse(markdown: String, url: URL) -> MeetingTranscript {
        // Simple parsing - in production, use a proper markdown parser
        let lines = markdown.split(separator: "\n")
        var meetingName = "Untitled Meeting"
        var startDate = Date()
        var segments: [TranscriptSegment] = []
        var notes = ""
        var summary = ""
        var section: String? = nil

        for line in lines {
            let line = String(line)

            if line.hasPrefix("# ") {
                meetingName = String(line.dropFirst(2))
            } else if line.hasPrefix("**Date:**") {
                // Parse date from markdown
                let dateStr = line.replacingOccurrences(of: "**Date:**", with: "").trimmingCharacters(in: .whitespaces)
                let formatter = DateFormatter()
                formatter.dateStyle = .medium
                formatter.timeStyle = .short
                if let date = formatter.date(from: dateStr) {
                    startDate = date
                }
            } else if line == "---" {
                section = nil
            } else if line == "## Notes" {
                section = "notes"
            } else if line == "## AI Summary" {
                section = "summary"
            } else if section == "notes" {
                notes += line + "\n"
            } else if section == "summary" {
                summary += line + "\n"
            } else if line.hasPrefix("[") && line.contains("]") && line.contains("**") {
                // Parse segment line like "[HH:MM:SS] **You:** text"
                if let segment = parseSegmentLine(line) {
                    segments.append(segment)
                }
            }
        }

        let transcript = MeetingTranscript(meetingName: meetingName)
        transcript.startDate = startDate
        transcript.segments = segments
        transcript.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        transcript.summary = summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : summary.trimmingCharacters(in: .whitespacesAndNewlines)
        transcript.isComplete = true

        return transcript
    }

    private func parseSegmentLine(_ line: String) -> TranscriptSegment? {
        // Format: [HH:MM:SS] **Speaker:** text
        let regex = try! NSRegularExpression(pattern: r"\[(\d{2}:\d{2}:\d{2})\]\s+\*\*(.+?)\*\*:\s+(.*)")
        let nsRange = NSRange(line.startIndex..., in: line)
        guard let match = regex.firstMatch(in: line, range: nsRange),
              match.numberOfRanges >= 4 else {
            return nil
        }

        let timestamp = (line as NSString).substring(with: match.rangeAt(1))
        let speakerName = (line as NSString).substring(with: match.rangeAt(2))
        let text = (line as NSString).substring(with: match.rangeAt(3))

        let speaker: SpeakerLabel = speakerName.lowercased() == "you" ? .me : .remote(name: speakerName)

        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        // Use today's date with the parsed time
        let today = Calendar.current.startOfDay(for: Date())
        let date = formatter.date(from: timestamp).map { today.addingTimeInterval($0.timeIntervalSinceReferenceDate - today.timeIntervalSinceReferenceDate) } ?? Date()

        return TranscriptSegment(
            timestamp: date,
            formattedTimestamp: timestamp,
            speaker: speaker,
            text: text,
            duration: 0
        )
    }
}

enum MeetingError: Error, LocalizedError {
    case cannotAccessStorage
    case invalidTranscript

    var errorDescription: String? {
        switch self {
        case .cannotAccessStorage: return "Cannot access meetings storage"
        case .invalidTranscript: return "Invalid transcript data"
        }
    }
}

// MARK: - SavedMeeting

struct SavedMeeting: Identifiable {
    let url: URL
    let fileName: String
    let modificationDate: Date

    var id: UUID {
        UUID(uuidString: fileName) ?? UUID()
    }

    var title: String {
        fileName.replacingOccurrences(of: "-", with: " ").capitalizingFirstLetter()
    }
}

extension String {
    func capitalizingFirstLetter() -> String {
        return prefix(1).uppercased() + dropFirst()
    }
}
