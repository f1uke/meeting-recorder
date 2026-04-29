import XCTest
@testable import Meeting

final class TranscriptMergerTests: XCTestCase {
    // MARK: - Fixtures

    private func micResult(
        segments: [(start: Double, end: Double, text: String)] = [],
        words: [(start: Double, end: Double, word: String)]? = nil
    ) -> TranscriptResult {
        let segs = segments.map {
            TranscriptSegment(
                start: $0.start, end: $0.end, speaker: .me, text: $0.text, source: .mic
            )
        }
        let wds = words?.map {
            TranscriptWord(word: $0.word, start: $0.start, end: $0.end, speaker: .me)
        }
        let dur = segments.map(\.end).max() ?? 0
        return TranscriptResult(
            provider: "MockMic",
            model: "tiny",
            language: "th",
            duration: dur,
            segments: segs,
            words: wds
        )
    }

    private func outputResult(
        segments: [(start: Double, end: Double, text: String, speaker: Int)] = []
    ) -> TranscriptResult {
        let segs = segments.map {
            TranscriptSegment(
                start: $0.start,
                end: $0.end,
                speaker: .diarized($0.speaker),
                text: $0.text,
                source: .meetingOutput
            )
        }
        let dur = segments.map(\.end).max() ?? 0
        return TranscriptResult(
            provider: "MockOutput",
            model: "tiny",
            language: "th",
            duration: dur,
            segments: segs,
            words: nil
        )
    }

    // MARK: - Order

    func test_mergedSegments_areSortedByStartTime() {
        let mic = micResult(segments: [
            (10.0, 12.0, "ฉันพูด"),
            (30.0, 32.0, "อีกที")
        ])
        let out = outputResult(segments: [
            (5.0, 7.0, "speaker zero", 0),
            (20.0, 22.0, "speaker one", 1),
            (35.0, 37.0, "back to zero", 0)
        ])

        let merged = TranscriptMerger.merge(mic: mic, output: out)

        let starts = merged.segments.map(\.start)
        XCTAssertEqual(starts, [5.0, 10.0, 20.0, 30.0, 35.0])
    }

    func test_mergedSegments_preserveSourceLabels() {
        let mic = micResult(segments: [(10.0, 12.0, "me")])
        let out = outputResult(segments: [(5.0, 7.0, "them", 0)])

        let merged = TranscriptMerger.merge(mic: mic, output: out)

        XCTAssertEqual(merged.segments.first?.source, .meetingOutput)
        XCTAssertEqual(merged.segments.last?.source, .mic)
    }

    // MARK: - Speakers

    func test_speakers_haveMeFirst_thenDiarizedAscending() {
        let mic = micResult(segments: [(10.0, 12.0, "me")])
        let out = outputResult(segments: [
            (5.0, 7.0, "two", 2),
            (20.0, 22.0, "zero", 0),
            (30.0, 32.0, "one", 1)
        ])

        let merged = TranscriptMerger.merge(mic: mic, output: out, meDisplayName: "ฉัน")

        XCTAssertEqual(merged.speakers.map(\.id),
                       [.me, .diarized(0), .diarized(1), .diarized(2)])
        XCTAssertEqual(merged.speakers.map(\.displayName),
                       ["ฉัน", "Speaker 1", "Speaker 2", "Speaker 3"])
    }

    func test_speakers_excludesUnseenSpeakers() {
        let mic = micResult(segments: [(10.0, 12.0, "me")])
        let out = outputResult(segments: [(5.0, 7.0, "only zero", 0)])

        let merged = TranscriptMerger.merge(mic: mic, output: out)

        XCTAssertEqual(merged.speakers.count, 2)
    }

    // MARK: - Words

    func test_words_areMergedAndSorted() {
        let mic = micResult(
            segments: [(10.0, 12.0, "ฉันพูด")],
            words: [(10.0, 11.0, "ฉัน"), (11.0, 12.0, "พูด")]
        )
        var out = outputResult(segments: [(5.0, 7.0, "เริ่ม", 0)])
        out = TranscriptResult(
            provider: out.provider,
            model: out.model,
            language: out.language,
            duration: out.duration,
            segments: out.segments,
            words: [TranscriptWord(word: "เริ่ม", start: 5.0, end: 6.0,
                                   speaker: .diarized(0))]
        )

        let merged = TranscriptMerger.merge(mic: mic, output: out)

        XCTAssertEqual(merged.words?.map(\.word), ["เริ่ม", "ฉัน", "พูด"])
        XCTAssertEqual(merged.words?.map(\.start), [5.0, 10.0, 11.0])
    }

    func test_words_areNilWhenNeitherProviderHasThem() {
        let mic = micResult(segments: [(10.0, 12.0, "me")])
        let out = outputResult(segments: [(5.0, 7.0, "them", 0)])
        let merged = TranscriptMerger.merge(mic: mic, output: out)
        XCTAssertNil(merged.words)
    }

    // MARK: - Misc

    func test_duration_takesMaxOfBoth() {
        let mic = micResult(segments: [(0.0, 50.0, "long")])
        let out = outputResult(segments: [(0.0, 30.0, "short", 0)])
        let merged = TranscriptMerger.merge(mic: mic, output: out)
        XCTAssertEqual(merged.duration, 50.0)
    }

    func test_providers_areDedupedAndOrdered() {
        let mic = micResult(segments: [(0.0, 1.0, "x")])
        let out = outputResult(segments: [(0.0, 1.0, "y", 0)])
        let merged = TranscriptMerger.merge(mic: mic, output: out)
        XCTAssertEqual(merged.providers, ["MockMic", "MockOutput"])
    }

    func test_diarizedIndex_parsesSpeakerN() {
        XCTAssertEqual(TranscriptMerger.diarizedIndex(.diarized(0)), 0)
        XCTAssertEqual(TranscriptMerger.diarizedIndex(.diarized(7)), 7)
        XCTAssertNil(TranscriptMerger.diarizedIndex(.me))
        XCTAssertNil(TranscriptMerger.diarizedIndex(SpeakerID(rawValue: "unknown")))
    }
}
