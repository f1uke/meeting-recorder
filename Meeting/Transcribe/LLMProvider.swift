import Foundation

// =============================================================================
// MARK: - Public types
// =============================================================================

/// LLM-generated insights for one meeting. Cached on disk at
/// `<meeting>/summary.json` so repeated opens of the Library detail pane
/// don't re-prompt — and so the Markdown meeting note can be rendered
/// locally from this same cache without a second LLM round-trip.
///
/// `tldr`, `keyDecisions`, and `discussionTopics` were added when the
/// note generation moved from a second Claude call to local rendering.
/// They're optional so legacy `summary.json` files written before that
/// change still decode — `MeetingNoteRenderer` falls back gracefully on
/// nil for the corresponding sections.
struct Summary: Codable, Equatable, Hashable, Sendable {
    var summary: String                      // 1-2 paragraph natural-language summary
    var actionItems: [ActionItem]
    var generatedAt: Date
    var providerName: String                 // e.g. "Claude CLI"
    /// One-line tldr in the transcript's primary language. Used as the
    /// `> blockquote` directly under the Markdown note's title.
    var tldr: String?
    /// Concrete decisions reached in the meeting — separate from action
    /// items (which are commitments/TODOs assigned to a person).
    var keyDecisions: [String]?
    /// 3-6 topical sections grouping related discussion across the
    /// meeting (NOT a chronological replay).
    var discussionTopics: [DiscussionTopic]?

    /// Whether this Summary has the rich fields needed to render a
    /// complete Markdown note. False for legacy summaries (pre-renderer)
    /// — callers re-run generation to upgrade.
    var hasRichFields: Bool {
        tldr != nil || keyDecisions != nil || discussionTopics != nil
    }
}

struct DiscussionTopic: Codable, Equatable, Hashable, Sendable, Identifiable {
    let id: UUID
    var heading: String
    var bullets: [String]

    init(id: UUID = UUID(), heading: String, bullets: [String]) {
        self.id = id
        self.heading = heading
        self.bullets = bullets
    }

    enum CodingKeys: String, CodingKey {
        case heading, bullets
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = UUID()
        self.heading = try c.decode(String.self, forKey: .heading)
        self.bullets = try c.decode([String].self, forKey: .bullets)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(heading, forKey: .heading)
        try c.encode(bullets, forKey: .bullets)
    }
}

struct ActionItem: Codable, Equatable, Sendable, Identifiable, Hashable {
    let id: UUID
    var speaker: String                      // display name ("You", "Pim", "Tar")
    var text: String
    /// "mm:ss" or "h:mm:ss" — kept as-is from the LLM, parsed on demand for
    /// timeline matching.
    var timestamp: String

    init(id: UUID = UUID(), speaker: String, text: String, timestamp: String) {
        self.id = id
        self.speaker = speaker
        self.text = text
        self.timestamp = timestamp
    }

    /// Parse `timestamp` into seconds. Returns nil for malformed strings.
    var timestampSeconds: TimeInterval? {
        let parts = timestamp.split(separator: ":").map { Double($0) ?? -1 }
        guard parts.allSatisfy({ $0 >= 0 }) else { return nil }
        switch parts.count {
        case 2: return parts[0] * 60 + parts[1]
        case 3: return parts[0] * 3600 + parts[1] * 60 + parts[2]
        default: return nil
        }
    }
}

// =============================================================================
// MARK: - Provider protocol
// =============================================================================

protocol LLMProvider: Sendable {
    var name: String { get }
    /// Whether the provider is usable right now (e.g. binary present, API
    /// key configured). Cheap — called from UI to disable / enable buttons.
    func availability() async -> LLMAvailability

    /// Generate the rich Summary (tldr, paragraph summary, decisions,
    /// action items, discussion topics) in a single LLM call. The
    /// Markdown meeting note is rendered locally from this — see
    /// `MeetingNoteRenderer` — so we never pay the input transcript
    /// cost twice.
    func generateSummary(context: MeetingLLMContext) async throws -> Summary
}

/// Bundle handed to `LLMProvider.generateSummary`. Beyond the bare
/// transcript, providers get the speaker→attendee mapping (so action
/// items can reference real participants) and the calendar event
/// (title + attendees give the model meeting purpose). `contextItems`
/// carries clipboard + browser-URL captures so the model can pull
/// links / quoted text into the summary. `meetingFolder` is the
/// folder all this meeting's artifacts live in — providers that
/// shell out to a CLI (like Claude) chdir into it so referenced
/// files (clipboard/<filename>.png, transcript.md, etc.) resolve
/// against the meeting's data root and the model can Read them
/// directly without absolute paths.
struct MeetingLLMContext: Sendable {
    let transcript: MergedTranscript
    let speakerProfiles: [SpeakerProfile]
    let calendarEvent: CalendarEvent?
    let contextItems: [ContextItem]
    let meetingFolder: URL
}

enum LLMAvailability: Sendable, Equatable {
    case available
    case missingBinary(String)   // e.g. "Claude Code is not installed"
    case authError(String)       // logged out / rate limited
    case unavailable(String)     // generic
}

enum LLMError: LocalizedError {
    case notInstalled(String)
    case launchFailed(String)
    case nonZeroExit(Int32, String)
    case decodeFailed(String)
    case empty

    var errorDescription: String? {
        switch self {
        case .notInstalled(let detail): "Claude CLI not installed: \(detail)"
        case .launchFailed(let detail): "Couldn't launch claude: \(detail)"
        case .nonZeroExit(let code, let stderr):
            "claude exited with status \(code).\n\n\(stderr)"
        case .decodeFailed(let detail): "Couldn't parse claude output: \(detail)"
        case .empty: "claude returned no output"
        }
    }
}

// =============================================================================
// MARK: - On-disk cache
// =============================================================================

extension Summary {
    static func read(from folder: URL) throws -> Summary {
        let url = folder.appendingPathComponent("summary.json")
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Summary.self, from: data)
    }

    func write(to folder: URL) throws {
        let url = folder.appendingPathComponent("summary.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: url, options: [.atomic])
    }
}
