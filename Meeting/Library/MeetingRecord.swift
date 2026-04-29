import Foundation

/// One row in the Library — a meeting folder with parsed-from-disk metadata
/// (folder name, transcript.json, marks.json) plus user-supplied overrides
/// from `library.json` (title, tags, starred flag, custom speaker names).
///
/// `id` is the folder's last path component (e.g. "2026-04-29_14-30-15") so
/// it stays stable across rescans and survives library.json regeneration.
struct MeetingRecord: Identifiable, Equatable, Hashable, Sendable {
    let folder: URL
    let recordedAt: Date

    /// User-overridable display title; falls back to the formatted date.
    let title: String
    let originalTitle: String?

    /// Total duration in seconds. `nil` if transcript.json is missing
    /// (recording incomplete or transcription not yet run).
    let duration: TimeInterval?

    /// Number of distinct speakers. 0 when no transcript.
    let speakerCount: Int

    /// Speaker IDs in transcript-defined order, with display names already
    /// resolved against custom overrides.
    let speakers: [Speaker]

    /// Application name from the meeting's source ("Zoom", "Discord"...)
    /// — derived from the picker at recording time. Not persisted yet
    /// in transcript.json, so this is nil for now and the Library detail
    /// pane shows folder name instead.
    let appName: String?

    let tags: [String]
    let starred: Bool
    let marks: [Mark]

    /// Whether this folder has a finished transcript on disk. Used to grey
    /// out detail-pane actions like "Open Transcript" or "Export".
    let hasTranscript: Bool

    /// Cached LLM summary, loaded from `summary.json` if present.
    let summary: Summary?

    var id: String { folder.lastPathComponent }
}

// MARK: - Stored overrides

/// On-disk shape of `library.json` at
/// `~/Library/Application Support/dev.fluke.meeting/library.json`.
struct LibraryOverrides: Codable, Sendable {
    var schemaVersion: Int
    var meetings: [String: MeetingOverride]

    init(schemaVersion: Int = 1, meetings: [String: MeetingOverride] = [:]) {
        self.schemaVersion = schemaVersion
        self.meetings = meetings
    }

    static func read(from url: URL) throws -> LibraryOverrides {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(LibraryOverrides.self, from: data)
    }

    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: url, options: [.atomic])
    }
}

/// User-supplied overrides for a single meeting. Keyed by folder name in
/// the parent `LibraryOverrides.meetings` map.
struct MeetingOverride: Codable, Equatable, Sendable {
    var title: String?
    var tags: [String]
    var starred: Bool
    /// Map of raw speaker id ("speaker_0") to display name ("Pim").
    var customSpeakerNames: [String: String]

    init(
        title: String? = nil,
        tags: [String] = [],
        starred: Bool = false,
        customSpeakerNames: [String: String] = [:]
    ) {
        self.title = title
        self.tags = tags
        self.starred = starred
        self.customSpeakerNames = customSpeakerNames
    }
}

// MARK: - Folder name parsing

enum MeetingFolderName {
    /// Parse a `2026-04-29_14-30-15` (or `…-2`) folder name into its base
    /// timestamp portion. Returns the folder name as-is if no match.
    /// Anchors on the full `yyyy-MM-dd_HH-mm-ss` shape so the trailing
    /// `-\d+` collision suffix is only stripped when it sits *after* a
    /// valid timestamp — otherwise a regex like `-\d+$` would eat the
    /// seconds (e.g. "…00-30-21" → "…00-30").
    static func stripCollisionSuffix(_ folderName: String) -> String {
        let pattern = #"^(\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2})(-\d+)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                  in: folderName,
                  range: NSRange(folderName.startIndex..., in: folderName)
              ),
              let baseRange = Range(match.range(at: 1), in: folderName)
        else {
            return folderName
        }
        return String(folderName[baseRange])
    }

    /// Decode the folder name into a `Date`. Returns `Date.distantPast` if
    /// the name doesn't match the expected timestamp pattern — keeps such
    /// folders sorted to the bottom rather than blowing up on optionals.
    static func date(from folderName: String) -> Date {
        let baseName = stripCollisionSuffix(folderName)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter.date(from: baseName) ?? .distantPast
    }
}
