import XCTest
import AppKit
@testable import Meeting

final class TextInjectorTests: XCTestCase {
    func test_joinSegments_collapsesAndTrims() {
        let segs = [
            TranscriptSegment(start: 0, end: 1, speaker: .me, text: "  hello ", source: .mic),
            TranscriptSegment(start: 1, end: 2, speaker: .me, text: "world  ", source: .mic),
        ]
        XCTAssertEqual(TextInjector.joinSegments(segs), "hello world")
    }

    func test_joinSegments_empty() {
        XCTAssertEqual(TextInjector.joinSegments([]), "")
    }

    func test_joinSegments_skipsBlankSegments() {
        let segs = [
            TranscriptSegment(start: 0, end: 1, speaker: .me, text: "หนึ่ง", source: .mic),
            TranscriptSegment(start: 1, end: 2, speaker: .me, text: "   ", source: .mic),
            TranscriptSegment(start: 2, end: 3, speaker: .me, text: "สอง", source: .mic),
        ]
        XCTAssertEqual(TextInjector.joinSegments(segs), "หนึ่ง สอง")
    }

    @MainActor
    func test_clipboardRoundTrip_restoresOriginal() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString("ORIGINAL", forType: .string)
        // Directly exercise the save/restore helpers (no key posting).
        let saved = TextInjector.snapshotString()
        pb.clearContents(); pb.setString("TEMP", forType: .string)
        TextInjector.restoreString(saved)
        XCTAssertEqual(pb.string(forType: .string), "ORIGINAL")
    }
}
