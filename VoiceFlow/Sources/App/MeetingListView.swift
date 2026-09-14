import SwiftUI

// MARK: - MeetingListView

struct MeetingListView: View {
    @StateObject private var history = MeetingHistory.shared
    @State private var searchText = ""
    @State private var selectedMeeting: SavedMeeting?

    var filteredMeetings: [SavedMeeting] {
        if searchText.isEmpty {
            return history.meetings
        }
        return history.search(searchText)
    }

    var body: some View {
        NavigationSplitView {
            VStack {
                SearchBar(text: $searchText)
                    .padding(.horizontal)

                List(filteredMeetings) { meeting in
                    MeetingRow(meeting: meeting)
                        .onTapGesture {
                            selectedMeeting = meeting
                        }
                }
                .listStyle(.plain)

                if history.meetings.isEmpty {
                    ContentUnavailableView(
                        "No Meetings",
                        systemImage: "calendar.badge.plus",
                        description: Text("Start recording your first meeting.")
                    )
                }
            }
            .navigationTitle("Meetings")
            .toolbar {
                ToolbarItem {
                    Button(action: { history.refresh() }) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Refresh")
                }
            }
        } detail: {
            if let meeting = selectedMeeting {
                MeetingDetailView(meeting: meeting)
            } else {
                ContentUnavailableView(
                    "Select a Meeting",
                    systemImage: "calendar",
                    description: Text("Choose a meeting from the list to view details.")
                )
            }
        }
        .task {
            await history.refresh()
        }
    }
}

// MARK: - MeetingRow

struct MeetingRow: View {
    let meeting: SavedMeeting

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "calendar")
                .font(.title2)
                .foregroundStyle(.blue)

            VStack(alignment: .leading, spacing: 4) {
                Text(meeting.title)
                    .font(.headline)
                Text(meeting.modificationDate.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - MeetingDetailView

struct MeetingDetailView: View {
    let meeting: SavedMeeting
    @State private var transcript: MeetingTranscript?
    @State private var isLoading = true
    @State private var error: String?

    var body: some View {
        ScrollView {
            Group {
                if let error {
                    ErrorView(message: error)
                } else if let transcript {
                    TranscriptView(transcript: transcript)
                } else if isLoading {
                    ProgressView("Loading...")
                }
            }
            .padding()
        }
        .navigationTitle(meeting.title)
        .task {
            await loadTranscript()
        }
    }

    private func loadTranscript() async {
        isLoading = true
        defer { isLoading = false }

        do {
            transcript = try await MeetingHistory.shared.getMeeting(at: meeting.url)
        } catch {
            self.error = "Failed to load meeting: \(error.localizedDescription)"
        }
    }
}

// MARK: - TranscriptView

struct TranscriptView: View {
    let transcript: MeetingTranscript

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            VStack(alignment: .leading, spacing: 8) {
                Text(transcript.meetingName)
                    .font(.largeTitle)
                    .bold()

                Text(transcript.startDate.formatted(date: .long, time: .shortened))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if !transcript.segments.isEmpty {
                    let speakers = Set(transcript.segments.map { $0.speaker.displayName })
                    Text("Participants: \(speakers.joined(separator: ", "))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 8)
            .divider()

            // Segments
            ForEach(transcript.segments) { segment in
                SegmentRow(segment: segment)
            }

            // Notes
            if !transcript.notes.isEmpty {
                Divider()
                    .padding(.vertical, 8)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Notes")
                        .font(.headline)
                    Text(transcript.notes)
                        .font(.body)
                        .textSelection(.enabled)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.gray.opacity(0.1))
                .cornerRadius(8)
            }

            // Summary
            if let summary = transcript.summary {
                Divider()
                    .padding(.vertical, 8)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("AI Summary")
                            .font(.headline)
                        Image(systemName: "wand.and.stars")
                            .foregroundStyle(.purple)
                    }
                    Text(summary)
                        .font(.body)
                        .textSelection(.enabled)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.purple.opacity(0.1))
                .cornerRadius(8)
            }
        }
    }
}

// MARK: - SegmentRow

struct SegmentRow: View {
    let segment: TranscriptSegment

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(segment.formattedTimestamp)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)

            Circle()
                .fill(segment.speaker == .me ? Color.blue : Color.green)
                .frame(width: 8, height: 8)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 4) {
                Text(segment.speaker.displayName)
                    .font(.caption)
                    .bold()
                    .foregroundStyle(segment.speaker == .me ? .blue : .green)

                Text(segment.text)
                    .font(.body)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 8)
    }
}

// MARK: - SearchBar

struct SearchBar: View {
    @Binding var text: String

    var body: some View {
        HStack {
            Image(systemName: "magnifying-glass")
                .foregroundStyle(.secondary)
            TextField("Search meetings...", text: $text)
                .textFieldStyle(.plain)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(8)
        .background(Color.gray.opacity(0.1))
        .cornerRadius(8)
    }
}

// MARK: - ErrorView

struct ErrorView: View {
    let message: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamation.triangle")
                .font(.system(size: 48))
                .foregroundStyle(.red)
            Text("Error")
                .font(.headline)
            Text(message)
                .font(.body)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}

// MARK: - Divider Extension

extension View {
    func divider() -> some View {
        self.padding(.vertical, 8)
    }
}
