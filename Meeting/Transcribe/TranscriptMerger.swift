import Foundation

/// Combines the mic transcript (single speaker = "me") with the meeting-output
/// transcript (multi-speaker via diarization) into one chronological timeline.
///
/// We don't try to dedupe overlapping speech here — the two streams come from
/// physically separate audio captures (CATap on the meeting app vs. the
/// microphone) so a "me" segment overlapping a "speaker_2" segment is a real
/// event (someone interrupted; the user spoke over them) and should appear in
/// the transcript as such.
struct MergedTranscript: Codable, Sendable {
    let duration: TimeInterval
    let language: String?
    let providers: [String]
    let segments: [TranscriptSegment]
    let speakers: [Speaker]
}

extension MergedTranscript {
    /// Read transcript.json from the meeting folder.
    static func read(from folder: URL) throws -> MergedTranscript {
        let url = folder.appendingPathComponent("transcript.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(MergedTranscript.self, from: data)
    }

    /// Atomically rewrite transcript.json after an in-app edit (segment
    /// rephrasing, speaker rename if we ever decide to bake it into the
    /// canonical transcript). For now speaker overrides live in
    /// library.json; this writer is only used for segment-text edits.
    func write(to folder: URL) throws {
        let url = folder.appendingPathComponent("transcript.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: [.atomic])
    }

    /// Replace one segment's text in-place. Returns a new MergedTranscript
    /// because segments are `let` to keep the type Sendable + Codable.
    func updatingSegment(id: TranscriptSegment.ID, text: String) -> MergedTranscript {
        let updated = segments.map { seg -> TranscriptSegment in
            guard seg.id == id else { return seg }
            return TranscriptSegment(
                id: seg.id,
                start: seg.start,
                end: seg.end,
                speaker: seg.speaker,
                text: text,
                source: seg.source
            )
        }
        return MergedTranscript(
            duration: duration,
            language: language,
            providers: providers,
            segments: updated,
            speakers: speakers
        )
    }

    /// Drop one segment from the timeline. Used by the Transcript Viewer's
    /// per-row delete action to remove hallucinated chunks or filler
    /// utterances. The on-disk `transcript.md` / `transcript.srt` exports
    /// don't auto-regenerate — the user re-runs the Export action when
    /// they want the derived files refreshed.
    func removingSegment(id: TranscriptSegment.ID) -> MergedTranscript {
        MergedTranscript(
            duration: duration,
            language: language,
            providers: providers,
            segments: segments.filter { $0.id != id },
            speakers: speakers
        )
    }
}

enum TranscriptMerger {
    /// Merges mic + output transcripts into a single sorted timeline. Speakers
    /// from each result are collected; mic gets `Speaker(id: .me, name: "Me")`
    /// and diarized speakers get default names "Speaker 1", "Speaker 2", ...
    /// (these are user-renamable later via the speaker rename UI).
    static func merge(
        mic: TranscriptResult,
        output: TranscriptResult,
        meDisplayName: String = "Me"
    ) -> MergedTranscript {
        var segments = mic.segments + output.segments
        segments.sort { $0.start < $1.start }

        let speakers = collectSpeakers(from: segments, meDisplayName: meDisplayName)

        let providers = [mic.provider, output.provider]
            .reduce(into: [String]()) { acc, p in if !acc.contains(p) { acc.append(p) } }

        return MergedTranscript(
            duration: max(mic.duration, output.duration),
            language: mic.language ?? output.language,
            providers: providers,
            segments: segments,
            speakers: speakers
        )
    }

    /// Default name for a speaker is "Me" for the mic source, "Speaker N" for
    /// each diarized id. Order: "Me" first, then by speaker id ascending.
    private static func collectSpeakers(
        from segments: [TranscriptSegment],
        meDisplayName: String
    ) -> [Speaker] {
        var seen: Set<SpeakerID> = []
        var ordered: [SpeakerID] = []
        for s in segments where !seen.contains(s.speaker) {
            seen.insert(s.speaker)
            ordered.append(s.speaker)
        }

        // Stable sort — "me" first, then diarized speakers in numeric order.
        ordered.sort { a, b in
            if a == .me { return b != .me }
            if b == .me { return false }
            return sortKey(a) < sortKey(b)
        }

        return ordered.map { id in
            if id == .me {
                return Speaker(id: id, displayName: meDisplayName)
            }
            if let idx = diarizedIndex(id) {
                return Speaker(id: id, displayName: "Speaker \(idx + 1)")
            }
            return Speaker(id: id, displayName: id.rawValue)
        }
    }

    /// Parses `speaker_N` into the integer N. Returns nil for `me` and any
    /// custom labels (e.g. "unknown") which sort last.
    static func diarizedIndex(_ id: SpeakerID) -> Int? {
        let prefix = "speaker_"
        guard id.rawValue.hasPrefix(prefix) else { return nil }
        return Int(id.rawValue.dropFirst(prefix.count))
    }

    private static func sortKey(_ id: SpeakerID) -> Int {
        diarizedIndex(id) ?? Int.max
    }
}
