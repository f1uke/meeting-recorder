import Foundation

/// One captured item from the user's environment during a recording —
/// something they copied, a link they opened, or an image from the
/// clipboard. Surfaced in the Library detail and (with delete affordance)
/// in the Transcript Viewer, then folded into the LLM summary prompt so
/// Claude can pull cited text / URLs into action items.
struct ContextItem: Codable, Identifiable, Equatable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case text       // plain string from clipboard
        case url        // URL string (clipboard) or visited page (browser)
        case image      // image bytes saved to clipboard/<filename>
    }

    enum Source: String, Codable, Sendable {
        case clipboard
        case browser
    }

    let id: UUID
    let kind: Kind
    let source: Source
    /// Absolute wall-clock time of capture.
    let capturedAt: Date
    /// Seconds since recording started — drives the inline `mm:ss`
    /// timestamp shown in the UI.
    let offset: TimeInterval
    /// Plain text payload for `.text`, the URL string for `.url`.
    var text: String?
    /// Relative filename inside the meeting's `clipboard/` subfolder for
    /// `.image`. Stored as a filename rather than absolute path so the
    /// meeting folder can be moved between disks without invalidating it.
    var imageFilename: String?
    /// Owning browser application for `.browser` source — "Safari",
    /// "Google Chrome", "Arc". Used for the icon + label only.
    var browserName: String?
    /// Tab title for `.browser` source — gives the user something more
    /// readable than the URL when scanning the list.
    var pageTitle: String?
}

/// Persisted on disk at `<meeting>/context.json`. Edits from the
/// Transcript Viewer's delete affordance rewrite this file in place.
struct ContextCaptureFile: Codable, Sendable, Equatable {
    static let filename = "context.json"
    static let currentVersion = 1

    let version: Int
    var items: [ContextItem]

    init(items: [ContextItem]) {
        self.version = Self.currentVersion
        self.items = items
    }

    static func read(from folder: URL) -> ContextCaptureFile? {
        let url = folder.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Self.self, from: data)
    }

    func write(to folder: URL) throws {
        let url = folder.appendingPathComponent(Self.filename)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    /// Subfolder that holds image payloads. Created lazily by the
    /// clipboard watcher when the first image arrives.
    static func imagesFolder(in meetingFolder: URL) -> URL {
        meetingFolder.appendingPathComponent("clipboard", isDirectory: true)
    }
}

/// Thread-safe sink for context items captured during a recording. Both
/// watchers push into the same collector; `RecordingSession.stop()`
/// drains it and writes `context.json`.
actor ContextCollector {
    private var items: [ContextItem] = []
    private let recordingStart: Date

    init(recordingStart: Date) {
        self.recordingStart = recordingStart
    }

    /// Append a new item, computing its `offset` from the recording start.
    /// Called from the watchers' background queues.
    func append(
        kind: ContextItem.Kind,
        source: ContextItem.Source,
        text: String? = nil,
        imageFilename: String? = nil,
        browserName: String? = nil,
        pageTitle: String? = nil,
        at date: Date = Date()
    ) {
        let item = ContextItem(
            id: UUID(),
            kind: kind,
            source: source,
            capturedAt: date,
            offset: max(0, date.timeIntervalSince(recordingStart)),
            text: text,
            imageFilename: imageFilename,
            browserName: browserName,
            pageTitle: pageTitle
        )
        items.append(item)
    }

    func snapshot() -> [ContextItem] {
        items
    }
}
