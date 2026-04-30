import Foundation
import SpeakerKit

/// Generic IoU-based merger for cloud transcription providers.
///
/// Pipeline: cloud provider returns text segments with timestamps, SpeakerKit
/// runs locally to produce a speaker timeline (`DiarizationResult.segments`),
/// then this merger labels each text segment with the speaker that owns the
/// largest fractional overlap. Texts with no overlap fall back to `unknown`.
///
/// This duplicates the IoU logic SpeakerKit's `addSpeakerInfo` does internally,
/// but operates on our generic `(start, end, text)` shape rather than
/// WhisperKit's `TranscriptionResult` — so any provider can hybrid-diarize
/// without fabricating WhisperKit types.
enum DiarizationMerger {
    /// One text chunk from the cloud provider's structured output.
    struct TextSegment: Sendable {
        let start: TimeInterval
        let end: TimeInterval
        let text: String
    }

    /// Assign each text segment a speaker by largest IoU with the speaker
    /// timeline. Returns chronologically-sorted `TranscriptSegment`s tagged
    /// with the supplied `source`.
    ///
    /// `unknown` is emitted when a text segment overlaps no speaker activity
    /// in the timeline (e.g. Pyannote ignored a stretch the cloud model
    /// transcribed). That should be rare in practice — both operate on the
    /// same audio — but we'd rather surface a labeled-as-unknown segment
    /// than silently drop text.
    static func merge(
        textSegments: [TextSegment],
        speakerTimeline: [SpeakerSegment],
        source: AudioSource
    ) -> [TranscriptSegment] {
        let timeline = speakerTimeline.sorted { $0.startTime < $1.startTime }
        var out: [TranscriptSegment] = []
        out.reserveCapacity(textSegments.count)

        for text in textSegments {
            let trimmed = text.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            // Drop YouTube-boilerplate hallucinations ("Thank you for watching",
            // music-note glyphs, ขอบคุณที่รับชมครับ) that the model emits on
            // silent output-stream chunks. LocalProvider applies this same
            // filter inside its mapDiarized; we do it here so the cloud
            // providers (Gemini, OpenAI) get the same scrubbing without each
            // duplicating the call.
            let dur = text.end - text.start
            if HallucinationFilter.isHallucination(text: trimmed, durationSeconds: dur) {
                continue
            }

            let speaker = bestSpeaker(for: text, timeline: timeline)
            out.append(TranscriptSegment(
                start: text.start,
                end: text.end,
                speaker: speaker,
                text: trimmed,
                source: source
            ))
        }

        out.sort { $0.start < $1.start }
        return out
    }

    /// Find the speaker timeline entry with the largest IoU against `text`.
    /// Linear scan — the timeline is small (hundreds of entries even for
    /// long meetings) so binary-searching the sorted array isn't worth it.
    private static func bestSpeaker(
        for text: TextSegment,
        timeline: [SpeakerSegment]
    ) -> SpeakerID {
        let textStart = text.start
        let textEnd = text.end
        guard textEnd > textStart else { return SpeakerID(rawValue: "unknown") }

        var bestScore: Double = 0
        var bestSpeakerId: Int?

        for entry in timeline {
            let entryStart = TimeInterval(entry.startTime)
            let entryEnd = TimeInterval(entry.endTime)

            // Sorted by startTime — once an entry begins after our text
            // ends, no later entry can overlap.
            if entryStart > textEnd { break }
            if entryEnd < textStart { continue }

            let intersection = min(textEnd, entryEnd) - max(textStart, entryStart)
            guard intersection > 0 else { continue }
            let union = max(textEnd, entryEnd) - min(textStart, entryStart)
            guard union > 0 else { continue }

            let score = intersection / union
            if score > bestScore, let id = entry.speaker.speakerId {
                bestScore = score
                bestSpeakerId = id
            }
        }

        if let id = bestSpeakerId {
            return SpeakerID.diarized(id)
        }
        return SpeakerID(rawValue: "unknown")
    }
}
