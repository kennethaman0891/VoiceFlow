import SwiftUI

// MARK: - ExportView

struct ExportView: View {
    @StateObject private var exporter = MeetingExporter.shared
    @State private var selectedFormat: ExportFormat = .markdown
    @State private var isExporting = false
    @State private var exportError: String?
    @State private var exportedURL: URL?

    var body: some View {
        VStack(spacing: 24) {
            Text("Export Meeting")
                .font(.title2)
                .bold()

            VStack(alignment: .leading, spacing: 16) {
                // Format selection
                VStack(alignment: .leading, spacing: 8) {
                    Text("Export Format")
                        .font(.headline)

                    Picker("Format", selection: $selectedFormat) {
                        ForEach(ExportFormat.allCases, id: \.self) { format in
                            HStack {
                                Image(systemName: format.icon)
                                Text(format.rawValue)
                            }
                        }
                    }
                    .pickerStyle(.options)
                }

                // Export button
                Button(action: performExport) {
                    if isExporting {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle())
                    } else {
                        Label("Export as \(selectedFormat.rawValue)", systemImage: selectedFormat.icon)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isExporting)
            }
            .padding()
            .background(Color(.windowBackgroundColor))
            .cornerRadius(12)

            // Result
            if let error = exportError {
                ErrorView(message: error)
            }

            if let url = exportedURL {
                SuccessView(url: url)
            }

            Spacer()
        }
        .padding()
        .frame(minWidth: 400, minHeight: 300)
    }

    // MARK: - Private

    private func performExport() {
        isExporting = true
        exportError = nil
        exportedURL = nil

        Task {
            do {
                // Use a sample transcript for demo
                let dummyTranscript = createDummyTranscript()
                let url = try await exporter.export(dummyTranscript, format: selectedFormat)
                exportedURL = url
            } catch {
                exportError = error.localizedDescription
            }
            isExporting = false
        }
    }

    private func createDummyTranscript() -> MeetingTranscript {
        let transcript = MeetingTranscript(meetingName: "Demo Meeting")
        transcript.segments = [
            TranscriptSegment(speaker: .me, text: "Welcome everyone to today's meeting.", duration: 3.2),
            TranscriptSegment(speaker: .remote(name: "Alice"), text: "Thanks for having me. I have some updates on the project.", duration: 4.1),
            TranscriptSegment(speaker: .me, text: "Great, please go ahead.", duration: 1.5)
        ]
        return transcript
    }
}

// MARK: - SuccessView

struct SuccessView: View {
    let url: URL

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)

            Text("Export Successful")
                .font(.headline)

            Text(url.lastPathComponent)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button("Open Folder") {
                    NSWorkspace.shared.open(url.deletingLastPathComponent())
                }
                .buttonStyle(.bordered)

                Button("Open File") {
                    NSWorkspace.shared.open(url)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
    }
}
