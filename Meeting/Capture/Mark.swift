import Foundation

/// A user-flagged moment during a recording. Captured by ⌘B (or the
/// "+ Mark" button) and persisted alongside the meeting at
/// `<meeting>/marks.json`. Notes are added later in the Transcript Viewer
/// (U7); during recording marks are timestamps only.
struct Mark: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    /// Seconds elapsed since the recording started.
    let timestamp: TimeInterval
    var note: String?

    init(id: UUID = UUID(), timestamp: TimeInterval, note: String? = nil) {
        self.id = id
        self.timestamp = timestamp
        self.note = note
    }
}

/// On-disk representation of a meeting's marks. Wrapped in a top-level
/// object so future fields (e.g. schemaVersion) can be added without
/// breaking decoders.
struct MarksFile: Codable, Sendable {
    var marks: [Mark]

    init(marks: [Mark]) { self.marks = marks }

    static func read(from folder: URL) throws -> MarksFile {
        let url = folder.appendingPathComponent("marks.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(MarksFile.self, from: data)
    }

    func write(to folder: URL) throws {
        let url = folder.appendingPathComponent("marks.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: url, options: [.atomic])
    }
}
