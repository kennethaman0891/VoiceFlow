import Foundation

// MARK: - MeetingDetector

/// Detects when a meeting is likely taking place based on heuristics.
final class MeetingDetector {
    static let shared = MeetingDetector()

    // MARK: - Public API

    /// Check if the current app/window suggests a meeting is in progress.
    func detectMeeting() -> DetectedMeeting? {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return nil
        }

        let name = app.localizedName ?? ""
        let bundleID = app.bundleIdentifier ?? ""

        // Known meeting apps
        let meetingIndicators: [(name: String, bundleID: String, confidence: Double)] = [
            ("Zoom", "us.zoom.xos", 0.95),
            ("Google Meet", "com.google.Chrome", 0.7),
            ("Microsoft Teams", "com.microsoft.teams", 0.95),
            ("Webex", "com.cisco.webexmeetings", 0.9),
            ("Slack", "com.tinyspeck.chatlyio", 0.6),
            ("Discord", "com.discord", 0.5)
        ]

        for indicator in meetingIndicators {
            if name.lowercased().contains(indicator.name.lowercased()) ||
               bundleID == indicator.bundleID {
                return DetectedMeeting(
                    appName: name,
                    bundleIdentifier: bundleID,
                    confidence: indicator.confidence
                )
            }
        }

        return nil
    }

    /// Auto-generate a meeting name based on context.
    func generateMeetingName() -> String {
        let detectors = [
            calendarMeetingName,
            detectedAppName,
            currentTimeName
        ]

        for detector in detectors {
            if let name = detector() {
                return name
            }
        }

        return "New Meeting"
    }

    // MARK: - Private

    private func calendarMeetingName() -> String? {
        let calendar = Calendar.current
        let now = Date()
        let oneHourAgo = now.addingTimeInterval(-3600)

        let eventFetcher = NSCalendar.fetchEvents(start: oneHourAgo, end: now)

        // Check for events starting in the next 5 minutes
        for event in eventFetcher {
            let diff = event.startDate.timeIntervalSince(now)
            if diff >= 0 && diff <= 300 { // Within 5 minutes
                return event.title ?? "Scheduled Meeting"
            }
        }

        return nil
    }

    private func detectedAppName() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let name = app.localizedName else {
            return nil
        }

        let meetingApps = ["Zoom", "Google Meet", "Teams", "Webex", "Slack"]
        for app in meetingApps {
            if name.lowercased().contains(app.lowercased()) {
                return "\(app) Call"
            }
        }

        return nil
    }

    private func currentTimeName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: Date())
    }
}

// MARK: - DetectedMeeting

struct DetectedMeeting: Equatable {
    let appName: String
    let bundleIdentifier: String
    let confidence: Double
}

// MARK: - Calendar Extension

extension NSCalendar {
    static func fetchEvents(start: Date, end: Date) -> [EventInfo] {
        var events: [EventInfo] = []
        let store = EKEventStore()

        // Get all calendars
        let calendars = store.calendars(for: .event)

        for calendar in calendars {
            let predicate = store.predicateForEvents(withStart: start, end: end, calendars: [calendar])
            let foundEvents = store.events(matching: predicate)
            events.append(contentsOf: foundEvents.map { EventInfo(title: $0.title, startDate: $0.startDate, endDate: $0.endDate) })
        }

        return events.sorted { $0.startDate < $1.startDate }
    }
}

struct EventInfo: Identifiable {
    let id = UUID()
    let title: String?
    let startDate: Date
    let endDate: Date
}
