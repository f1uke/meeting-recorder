import AVFoundation
import CoreMedia
import XCTest
@testable import Meeting

final class MeetingVideoExporterTests: XCTestCase {

    // MARK: - Cue building

    private func transcript(
        _ segs: [(start: Double, end: Double, speaker: SpeakerID, text: String)],
        speakers: [Speaker] = []
    ) -> MergedTranscript {
        MergedTranscript(
            duration: segs.map(\.end).max() ?? 0,
            language: "th",
            providers: ["Mock"],
            segments: segs.map {
                TranscriptSegment(start: $0.start, end: $0.end, speaker: $0.speaker, text: $0.text,
                                  source: $0.speaker == .me ? .mic : .meetingOutput)
            },
            speakers: speakers
        )
    }

    func test_cues_prefixSpeakerName_andSortByStart() {
        let t = transcript(
            [(2.0, 3.0, .diarized(0), "world"), (0.0, 1.0, .me, "hello")],
            speakers: [Speaker(id: .me, displayName: "Me"), Speaker(id: .diarized(0), displayName: "Alex")]
        )
        let cues = TimedText.cues(from: t, names: [:])
        XCTAssertEqual(cues.map(\.text), ["Me: hello", "Alex: world"])
        XCTAssertEqual(cues.first?.start, 0.0)
    }

    func test_cues_explicitNamesOverrideTranscript() {
        let t = transcript([(0, 1, .diarized(0), "hi")],
                           speakers: [Speaker(id: .diarized(0), displayName: "speaker_0")])
        let cues = TimedText.cues(from: t, names: [.diarized(0): "Boss"])
        XCTAssertEqual(cues.first?.text, "Boss: hi")
    }

    func test_cues_fallBackToRawIDWhenUnnamed() {
        let t = transcript([(0, 1, .diarized(3), "hi")])
        XCTAssertEqual(TimedText.cues(from: t, names: [:]).first?.text, "speaker_3: hi")
    }

    func test_cues_clampOverlapsSoTheyNeverCoexist() {
        let t = transcript(
            [(0.0, 5.0, .me, "a"), (3.0, 6.0, .diarized(0), "b")],
            speakers: [Speaker(id: .me, displayName: "Me"), Speaker(id: .diarized(0), displayName: "X")]
        )
        let cues = TimedText.cues(from: t, names: [:])
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[0].end, 5.0)
        XCTAssertEqual(cues[1].start, 5.0, "second cue starts where the first ends")
        XCTAssertEqual(cues[1].end, 6.0)
    }

    func test_cues_dropZeroAndNegativeDuration() {
        let t = transcript([(1.0, 1.0, .me, "empty"), (2.0, 1.5, .me, "backwards")],
                           speakers: [Speaker(id: .me, displayName: "Me")])
        XCTAssertTrue(TimedText.cues(from: t, names: [:]).isEmpty)
    }

    // MARK: - tx3g sample payload

    func test_sampleData_lengthPrefixedUTF8() {
        let data = TimedText.sampleData("Hi")
        XCTAssertEqual(Array(data), [0x00, 0x02, 0x48, 0x69]) // len=2, "Hi"
    }

    func test_sampleData_emptyIsTwoZeroBytes() {
        XCTAssertEqual(Array(TimedText.sampleData("")), [0x00, 0x00])
    }

    func test_sampleData_thaiUsesUTF8ByteCount() {
        let text = "สวัสดี"
        let data = TimedText.sampleData(text)
        let utf8 = Array(text.utf8)
        let declaredLen = Int(data[0]) << 8 | Int(data[1])
        XCTAssertEqual(declaredLen, utf8.count)
        XCTAssertEqual(Array(data.dropFirst(2)), utf8)
    }

    // MARK: - tx3g format description (guards the byte layout)

    func test_formatDescription_isTx3gSubtitle() throws {
        let fmt = try XCTUnwrap(Tx3g.makeFormatDescription())
        XCTAssertEqual(CMFormatDescriptionGetMediaType(fmt), kCMMediaType_Subtitle)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(fmt), kCMTextFormatType_3GText)
    }

    func test_sampleBuffer_buildsReadyBuffer() throws {
        let fmt = try XCTUnwrap(Tx3g.makeFormatDescription())
        let buffer = try XCTUnwrap(Tx3g.sampleBuffer(
            text: "Me: hello",
            start: .zero,
            duration: CMTime(value: 1, timescale: 1),
            format: fmt))
        XCTAssertTrue(CMSampleBufferIsValid(buffer))
        XCTAssertEqual(CMSampleBufferGetNumSamples(buffer), 1)
        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(buffer), .zero)
    }
}
