import Foundation

// MARK: - Speaker

/// Stable identifier for a speaker within a meeting. The raw string is what
/// providers emit (e.g. "speaker_0", "me"); the user-visible label lives on
/// the matching `Speaker` record so renaming is non-destructive.
struct SpeakerID: Hashable, Codable, Sendable, RawRepresentable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }

    static let me = SpeakerID(rawValue: "me")

    static func diarized(_ index: Int) -> SpeakerID {
        SpeakerID(rawValue: "speaker_\(index)")
    }
}

struct Speaker: Hashable, Codable, Sendable, Identifiable {
    let id: SpeakerID
    var displayName: String
}

// MARK: - Transcript types

/// Which microphone the segment came from. Drives merging order and styling.
enum AudioSource: String, Codable, Sendable {
    case mic            // user's own voice (single speaker)
    case meetingOutput  // meeting app's audio (diarized into multiple speakers)
}

/// A contiguous span of speech from a single speaker.
struct TranscriptSegment: Codable, Hashable, Sendable, Identifiable {
    var id: UUID = UUID()
    let start: TimeInterval
    let end: TimeInterval
    let speaker: SpeakerID
    let text: String
    let source: AudioSource

    enum CodingKeys: String, CodingKey {
        case id, start, end, speaker, text, source
    }
}

/// Word-level timing — used internally to align with diarization turns and to
/// drive scroll-sync in the transcript viewer. Optional in the canonical JSON.
struct TranscriptWord: Codable, Hashable, Sendable {
    let word: String
    let start: TimeInterval
    let end: TimeInterval
    var speaker: SpeakerID?
}

/// Full result of one transcription run on a single audio file.
struct TranscriptResult: Codable, Sendable {
    let provider: String
    let model: String?
    let language: String?
    let duration: TimeInterval
    let segments: [TranscriptSegment]
    let words: [TranscriptWord]?
}

// MARK: - Provider

struct TranscriptionOptions: Sendable {
    /// `nil` = auto-detect. ISO 639-1 codes for explicit languages.
    var language: String?
    /// Run speaker diarization. Mic audio passes false; meeting output passes true.
    var withDiarization: Bool
    /// Pre-assigned speaker for sources we already know (e.g. mic = "me"). When
    /// non-nil, no diarization is needed because every word is from this speaker.
    var knownSpeaker: SpeakerID?
    /// Stamps every emitted segment with this source so the merger can keep
    /// mic/output streams distinguishable downstream.
    var source: AudioSource
    /// Force the diarizer to a specific speaker count. `nil` = auto-detect
    /// (pyannote default). Set to 1 for solo monologues; set to a known small
    /// number when over-segmentation is splitting one voice across labels.
    var expectedSpeakerCount: Int?

    init(
        language: String? = nil,
        withDiarization: Bool = false,
        knownSpeaker: SpeakerID? = nil,
        source: AudioSource,
        expectedSpeakerCount: Int? = nil
    ) {
        self.language = language
        self.withDiarization = withDiarization
        self.knownSpeaker = knownSpeaker
        self.source = source
        self.expectedSpeakerCount = expectedSpeakerCount
    }
}

protocol TranscriptionProvider: Sendable {
    /// Display name for Settings + transcript metadata.
    var name: String { get }
    /// Transcribe one audio file. `progress` (when non-nil) is called with a
    /// fraction in 0...1 representing this single call's progress through the
    /// audio — including diarization when `options.withDiarization` is set.
    /// Reporting is best-effort and may emit nothing if the underlying model
    /// doesn't expose progress.
    func transcribe(
        audioURL: URL,
        options: TranscriptionOptions,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> TranscriptResult
    /// Release any loaded model weights from memory. Called by the session
    /// after a transcript completes so the multi-GB CoreML buffers don't sit
    /// resident for the rest of the app's lifetime.
    func unloadModels() async
}

extension TranscriptionProvider {
    func unloadModels() async {}
    func transcribe(audioURL: URL, options: TranscriptionOptions) async throws -> TranscriptResult {
        try await transcribe(audioURL: audioURL, options: options, progress: nil)
    }
}

enum TranscriptionError: LocalizedError {
    case audioMissing(URL)
    case modelLoadFailed(String)
    case providerFailed(String, underlying: Error)

    var errorDescription: String? {
        switch self {
        case .audioMissing(let url): "ไฟล์เสียงหาย: \(url.path)"
        case .modelLoadFailed(let what): "โหลดโมเดล \(what) ไม่ได้"
        case .providerFailed(let p, let e): "Provider \(p) ผิดพลาด: \(e.localizedDescription)"
        }
    }
}
