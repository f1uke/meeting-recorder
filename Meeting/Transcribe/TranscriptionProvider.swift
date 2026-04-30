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

/// Full result of one transcription run on a single audio file.
struct TranscriptResult: Codable, Sendable {
    let provider: String
    let model: String?
    let language: String?
    let duration: TimeInterval
    let segments: [TranscriptSegment]
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
    /// Time ranges (in seconds since audio start) whose audio should be
    /// silenced before Whisper sees it. Used to skip muted-mic regions so
    /// the model doesn't hallucinate boilerplate over echo / ambient noise.
    /// `nil` or empty = no gating (the file is transcribed as-is). Providers
    /// that can't honor this fall back to ungated transcription.
    var mutedIntervals: [MutedInterval]?
    /// Far-end audio signal used to cancel speaker echo from the mic
    /// stream via NLMS adaptive filtering. Only set on mic transcription
    /// (typically the meeting's captured `output.m4a`); leave nil for the
    /// output stream itself.
    var referenceAudioURL: URL?
    /// Boost gain so the audio's peak hits a target dBFS before Whisper
    /// sees it. Quiet recordings (e.g. a built-in mic far from the user)
    /// otherwise produce log-mel features dominated by noise floor and
    /// trigger more hallucinations.
    var normalizeLoudness: Bool

    init(
        language: String? = nil,
        withDiarization: Bool = false,
        knownSpeaker: SpeakerID? = nil,
        source: AudioSource,
        expectedSpeakerCount: Int? = nil,
        mutedIntervals: [MutedInterval]? = nil,
        referenceAudioURL: URL? = nil,
        normalizeLoudness: Bool = false
    ) {
        self.language = language
        self.withDiarization = withDiarization
        self.knownSpeaker = knownSpeaker
        self.source = source
        self.expectedSpeakerCount = expectedSpeakerCount
        self.mutedIntervals = mutedIntervals
        self.referenceAudioURL = referenceAudioURL
        self.normalizeLoudness = normalizeLoudness
    }
}

/// One audio stream tied to its options. Used as the input shape of
/// `transcribeBatch(...)` so providers that benefit from bundling
/// (Gemini Batch API) can route every stream's chunks through one
/// server-side job.
struct TranscribeStream: Sendable {
    let audioURL: URL
    let options: TranscriptionOptions
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
    /// Transcribe several streams together. The default extension impl
    /// runs them sequentially via `transcribe(...)` — a behavior-preserving
    /// fallback for local engines and synchronous cloud paths. Providers
    /// that can do better (e.g. GeminiProvider with Batch API on, where
    /// every stream's chunks go into one batch job) override this directly.
    /// Returns a dictionary keyed by `audioURL` so callers don't need to
    /// reason about input ordering.
    func transcribeBatch(
        streams: [TranscribeStream],
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> [URL: TranscriptResult]
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

    /// Default `transcribeBatch` — sequential `transcribe()` per stream.
    /// Slices the caller's progress band evenly across streams so the bar
    /// keeps moving regardless of stream count.
    func transcribeBatch(
        streams: [TranscribeStream],
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> [URL: TranscriptResult] {
        var results: [URL: TranscriptResult] = [:]
        let total = Double(max(streams.count, 1))
        for (i, stream) in streams.enumerated() {
            let bandStart = Double(i) / total
            let bandSize = 1.0 / total
            let result = try await transcribe(
                audioURL: stream.audioURL,
                options: stream.options,
                progress: { f in
                    progress?(bandStart + max(0, min(1, f)) * bandSize)
                }
            )
            results[stream.audioURL] = result
        }
        return results
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
