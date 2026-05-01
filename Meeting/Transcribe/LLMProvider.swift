import Foundation

// =============================================================================
// MARK: - Public types
// =============================================================================

/// LLM-generated summary + action items for one meeting. Cached on disk
/// at `<meeting>/summary.json` so repeated opens of the Library detail
/// pane don't re-prompt.
struct Summary: Codable, Equatable, Hashable, Sendable {
    var summary: String                      // 1-2 paragraph natural-language summary
    var actionItems: [ActionItem]
    var generatedAt: Date
    var providerName: String                 // e.g. "Claude CLI"
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

    func generateSummary(context: MeetingLLMContext) async throws -> Summary
}

/// Bundle handed to `LLMProvider.generateSummary`. Beyond the bare
/// transcript, providers get the speaker→attendee mapping (so action
/// items can reference real participants) and the calendar event
/// (title + attendees give the model meeting purpose). `contextItems`
/// carries clipboard + browser-URL captures so the model can pull
/// links / quoted text into the summary.
struct MeetingLLMContext: Sendable {
    let transcript: MergedTranscript
    let speakerProfiles: [SpeakerProfile]
    let calendarEvent: CalendarEvent?
    let contextItems: [ContextItem]
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
