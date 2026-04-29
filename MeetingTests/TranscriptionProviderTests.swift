import XCTest
@testable import Meeting

final class TranscriptionProviderTests: XCTestCase {
    // MARK: - SpeakerID

    func test_speakerID_meIsSingleton() {
        XCTAssertEqual(SpeakerID.me.rawValue, "me")
        XCTAssertEqual(SpeakerID.me, SpeakerID(rawValue: "me"))
    }

    func test_speakerID_diarizedFormat() {
        XCTAssertEqual(SpeakerID.diarized(3).rawValue, "speaker_3")
        XCTAssertNotEqual(SpeakerID.diarized(0), SpeakerID.diarized(1))
    }

    // MARK: - Codable round-trip

    func test_transcriptResult_roundTrip() throws {
        let original = TranscriptResult(
            provider: "P",
            model: "m",
            language: "th",
            duration: 12.5,
            segments: [
                TranscriptSegment(
                    start: 0.0, end: 2.0,
                    speaker: .me, text: "hi", source: .mic
                )
            ]
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TranscriptResult.self, from: data)

        XCTAssertEqual(decoded.provider, original.provider)
        XCTAssertEqual(decoded.duration, original.duration)
        XCTAssertEqual(decoded.segments.count, 1)
        XCTAssertEqual(decoded.segments[0].speaker, .me)
        XCTAssertEqual(decoded.segments[0].source, .mic)
    }

    func test_transcriptSegment_idIsStableAcrossEncoding() throws {
        let original = TranscriptSegment(
            start: 0, end: 1, speaker: .diarized(0),
            text: "x", source: .meetingOutput
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TranscriptSegment.self, from: data)
        XCTAssertEqual(decoded.id, original.id)
    }
}
