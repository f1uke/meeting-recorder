import Foundation

/// Sendable snapshot of an `EKEvent` taken at recording time. We don't keep
/// the live `EKEvent` reference around because it's bound to an
/// `EKEventStore` actor and gets invalidated on store changes. Instead the
/// fields we actually use (title, attendees, conference URL, …) get
/// captured into this value type, persisted next to the recording, and
/// surfaced through the Library pipeline like any other meeting metadata.
struct CalendarEvent: Codable, Equatable, Hashable, Sendable, Identifiable {
    /// EKEvent.eventIdentifier — stable for non-recurring events, changes
    /// per occurrence for recurring ones.
    let eventIdentifier: String
    /// EKEvent.calendarItemExternalIdentifier — stable across all
    /// occurrences of a recurring series. We use this for the "group all
    /// recordings of the weekly 1:1" feature later, so capture it now.
    let externalIdentifier: String?
    let title: String
    let startDate: Date
    let endDate: Date
    let location: String?
    /// Best-effort conference URL extracted from notes/location/url. Used
    /// by the auto-detect matcher to score against the picker's chosen
    /// window app (Zoom URL → Zoom window).
    let conferenceURL: URL?
    let calendarName: String?
    let organizer: CalendarAttendee?
    let attendees: [CalendarAttendee]
    /// Optional URL the user can click to jump back to Calendar.app.
    /// Set to `x-apple-calevent://<eventIdentifier>`.
    let openInCalendarURL: URL?

    var id: String { eventIdentifier }

    /// Number of attendees including the organizer (deduplicated by email).
    var totalAttendeeCount: Int {
        var seen = Set<String>()
        if let organizerEmail = organizer?.email?.lowercased() {
            seen.insert(organizerEmail)
        }
        for a in attendees {
            if let e = a.email?.lowercased() { seen.insert(e) }
        }
        // Fall back to count if no emails (e.g. all attendees are name-only).
        if seen.isEmpty { return attendees.count + (organizer == nil ? 0 : 1) }
        return seen.count
    }

    var isHappeningNow: Bool {
        let now = Date()
        return startDate <= now && now <= endDate
    }
}

struct CalendarAttendee: Codable, Equatable, Hashable, Sendable, Identifiable {
    /// Stable per-event id derived from email or name (whichever exists)
    /// so SwiftUI ForEach has something to key off of.
    var id: String {
        if let email, !email.isEmpty { return "email:\(email.lowercased())" }
        return "name:\(displayName)"
    }
    /// Best-effort display name. Calendar often only gives an email — in
    /// that case we use the local-part as a stand-in (e.g. "fluke@foo" →
    /// "fluke") so the UI has something readable.
    let displayName: String
    let email: String?
    /// True if this attendee is the same user the app is running as.
    /// CalendarStore checks the matched email against the user's identity.
    let isMe: Bool
    /// EKParticipantRole raw — "required", "optional", "non-participant",
    /// "chair", "unknown". Captured for completeness; not displayed yet.
    let role: String?
    /// EKParticipantStatus raw — "accepted", "declined", "tentative",
    /// "pending", "delegated", "completed", "in-process", "unknown".
    /// Used by AutoRecordEligibility to skip events the user declined.
    /// Optional so old `calendar.json` files decode unchanged.
    let status: String?
}

// MARK: - On-disk file

/// `<meeting>/calendar.json` — written by RecordingSession on stop when
/// the user attached a calendar event before starting. Layered into
/// `MeetingRecord` by the Library scan.
struct CalendarEventFile: Codable, Sendable {
    var schemaVersion: Int
    var event: CalendarEvent

    init(schemaVersion: Int = 1, event: CalendarEvent) {
        self.schemaVersion = schemaVersion
        self.event = event
    }

    static func read(from folder: URL) throws -> CalendarEventFile {
        let url = folder.appendingPathComponent("calendar.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder.calendarEvent.decode(CalendarEventFile.self, from: data)
    }

    func write(to folder: URL) throws {
        let url = folder.appendingPathComponent("calendar.json")
        let data = try JSONEncoder.calendarEvent.encode(self)
        try data.write(to: url, options: [.atomic])
    }
}

extension JSONEncoder {
    static let calendarEvent: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}

extension JSONDecoder {
    static let calendarEvent: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
