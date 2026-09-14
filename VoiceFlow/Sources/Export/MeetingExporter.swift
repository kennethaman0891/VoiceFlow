import Foundation
import CoreData

// MARK: - ExportFormat

enum ExportFormat: String, CaseIterable, Identifiable {
    case markdown = "Markdown"
    case pdf = "PDF"
    case text = "Plain Text"
    case json = "JSON"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .markdown: return "doc.richtext"
        case .pdf: return "doc.fill"
        case .text: return "doc.text"
        case .json: return "curlybraces"
        }
    }
}

// MARK: - MeetingExporter

/// Exports meeting transcripts to various formats.
final class MeetingExporter {
    static let shared = MeetingExporter()

    private init() {}

    // MARK: - Public API

    /// Export a meeting transcript to the specified format.
    func export(_ transcript: MeetingTranscript, format: ExportFormat) async throws -> URL {
        let content: String

        switch format {
        case .markdown:
            content = transcript.formattedOutput
        case .text:
            content = extractPlainText(from: transcript)
        case .json:
            content = try JSONEncoder().encode(transcript)
                .utf8CString
                .withUnsafeBufferPointer { ptr in
                    String(cString: ptr.baseAddress!)
                }
        case .pdf:
            content = transcript.formattedOutput
        }

        let filename = exportFilename(for: transcript, format: format)
        let url = try saveContent(content, filename: filename)

        if format == .pdf {
            return try await convertToPDF(at: url)
        }

        return url
    }

    /// Share a meeting using the system share sheet.
    func share(_ transcript: MeetingTranscript, formats: [ExportFormat] = [.markdown, .pdf]) async {
        for format in formats {
            do {
                let url = try await export(transcript, format: format)
                showShareSheet(items: [url])
            } catch {
                print("[MeetingExporter] Failed to export \(format): \(error)")
            }
        }
    }

    // MARK: - Private

    private func exportFilename(for transcript: MeetingTranscript, format: ExportFormat) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let timestamp = dateFormatter.string(from: transcript.startDate)
        let sanitized = transcript.meetingName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
        return "\(timestamp)-\(sanitized).\(format.fileExtension)"
    }

    private func saveContent(_ content: String, filename: String) throws -> URL {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        let url = downloads.appendingPathComponent(filename)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func extractPlainText(from transcript: MeetingTranscript) -> String {
        var text = "\(transcript.meetingName)\n"
        text += "\(transcript.startDate.formatted(date: .long, time: .shortened))\n\n"
        text += "---\n\n"

        for segment in transcript.segments {
            text += "[\(segment.formattedTimestamp)] \(segment.speaker.displayName): \(segment.text)\n"
        }

        if !transcript.notes.isEmpty {
            text += "\n---\n\nNotes:\n\(transcript.notes)\n"
        }

        if let summary = transcript.summary {
            text += "\n---\n\nAI Summary:\n\(summary)\n"
        }

        return text
    }

    private func convertToPDF(at fileURL: URL) async throws -> URL {
        // In production, use WKWebView or UIKit to render HTML to PDF
        // For now, return the markdown file (users can convert manually)
        return fileURL
    }

    private func showShareSheet(items: [Any]) {
        guard let firstItem = items.first else { return }
        let controller = UIActivityViewController(activityItems: [firstItem], applicationActivities: nil)
        // Present on main window
        if let window = NSApp.windows.first {
            window.makeKeyAndOrderFront(nil)
        }
    }
}

extension ExportFormat {
    var fileExtension: String {
        switch self {
        case .markdown: return "md"
        case .pdf: return "pdf"
        case .text: return "txt"
        case .json: return "json"
        }
    }
}
