import XCTest
@testable import Meeting

final class ActionItemTests: XCTestCase {
    func test_timestampSeconds_parsesMMSS() {
        XCTAssertEqual(item("00:00").timestampSeconds, 0)
        XCTAssertEqual(item("00:30").timestampSeconds, 30)
        XCTAssertEqual(item("14:22").timestampSeconds, 14 * 60 + 22)
        XCTAssertEqual(item("59:59").timestampSeconds, 59 * 60 + 59)
    }

    func test_timestampSeconds_parsesHHMMSS() {
        XCTAssertEqual(item("1:00:00").timestampSeconds, 3600)
        XCTAssertEqual(item("2:14:22").timestampSeconds, 2 * 3600 + 14 * 60 + 22)
    }

    func test_timestampSeconds_returnsNilOnGarbage() {
        XCTAssertNil(item("").timestampSeconds)
        XCTAssertNil(item("not a time").timestampSeconds)
        XCTAssertNil(item("12").timestampSeconds)
        XCTAssertNil(item("a:b:c").timestampSeconds)
        XCTAssertNil(item("1:2:3:4").timestampSeconds)
    }

    func test_codable_roundTrip() throws {
        let original = ActionItem(speaker: "Pim", text: "Move Aof", timestamp: "14:22")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ActionItem.self, from: data)
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.speaker, original.speaker)
        XCTAssertEqual(decoded.text, original.text)
        XCTAssertEqual(decoded.timestamp, original.timestamp)
    }

    private func item(_ stamp: String) -> ActionItem {
        ActionItem(speaker: "Test", text: "T", timestamp: stamp)
    }
}
