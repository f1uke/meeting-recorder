import Foundation

/// Per-speaker metadata, persisted alongside the meeting at
/// `<meeting>/speakers.json`. Goes beyond the on-transcript `Speaker`
/// (which is just `id` + `displayName`) to capture the calendar
/// attendee that a speaker was mapped to — keeping a stable handle on
/// the *person* rather than just whatever name happened to be typed.
///
/// The richer fields drive two things:
///   1. The LLM summary prompt — Claude gets a roster ("Pim is the
///      organizer at pim@example.com") so action items can attribute
///      commitments to a real participant rather than a label.
///   2. Future cross-meeting analytics — `attendeeId` is stable across
///      meetings (it comes from `CalendarAttendee.id`, which is the
///      lowercased email or name), so queries like "all meetings where
///      Pim spoke" can group on the id without fragile name matching.
struct SpeakerProfile: Codable, Hashable, Sendable {
    let id: SpeakerID
    var displayName: String
    /// `CalendarAttendee.id` — `email:<addr>` or `name:<name>` — when
    /// the speaker was assigned via the Attendees drag pool. nil for
    /// hand-typed names where we don't know which calendar invitee
    /// (if any) the user meant.
    var attendeeId: String?
    var email: String?
    /// `EKParticipantRole` raw value at the moment the mapping was
    /// made: "required", "optional", "chair", "non-participant",
    /// "unknown". Captured for LLM prompt context — knowing the chair
    /// changes how Claude weighs "I'll do X" vs "you should do X".
    var role: String?

    init(
        id: SpeakerID,
        displayName: String,
        attendeeId: String? = nil,
        email: String? = nil,
        role: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.attendeeId = attendeeId
        self.email = email
        self.role = role
    }

    /// Drop down to the lightweight `Speaker` value for places that
    /// only care about `(id, displayName)` (transcript rendering,
    /// avatar rows).
    var asSpeaker: Speaker {
        Speaker(id: id, displayName: displayName)
    }
}

/// On-disk shape of `<meeting>/speakers.json`.
///
/// Authoritative when present: the loader prefers this over the legacy
/// `MeetingOverride.customSpeakerNames` map in `library.json`. New
/// edits in the Speakers panel always write here, so library.json
/// never picks up new mapping data going forward.
struct SpeakerMapFile: Codable, Sendable {
    var schemaVersion: Int
    var speakers: [SpeakerProfile]

    init(schemaVersion: Int = 1, speakers: [SpeakerProfile] = []) {
        self.schemaVersion = schemaVersion
        self.speakers = speakers
    }

    static func read(from folder: URL) throws -> SpeakerMapFile {
        let url = folder.appendingPathComponent("speakers.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(SpeakerMapFile.self, from: data)
    }

    func write(to folder: URL) throws {
        let url = folder.appendingPathComponent("speakers.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: [.atomic])
    }
}
