import XCTest
@testable import Meeting

final class ExpectedSpeakersTests: XCTestCase {
    func test_pyannoteValue_returnsNilForAuto() {
        XCTAssertNil(ExpectedSpeakers.auto.pyannoteValue)
    }

    func test_pyannoteValue_returnsCountForExact() {
        XCTAssertEqual(ExpectedSpeakers.exact(1).pyannoteValue, 1)
        XCTAssertEqual(ExpectedSpeakers.exact(5).pyannoteValue, 5)
    }

    func test_storageRoundTrip_preservesAuto() {
        let auto = ExpectedSpeakers.auto
        XCTAssertEqual(ExpectedSpeakers(storageValue: auto.storageValue), .auto)
    }

    func test_storageRoundTrip_preservesExact() {
        for n in 1...8 {
            let original = ExpectedSpeakers.exact(n)
            let restored = ExpectedSpeakers(storageValue: original.storageValue)
            XCTAssertEqual(restored, original)
        }
    }

    func test_storageNil_decodesToAuto() {
        XCTAssertEqual(ExpectedSpeakers(storageValue: nil), .auto)
    }

    func test_storageZero_decodesToAuto() {
        // Zero is invalid (no point asking for 0 speakers); fall back to auto.
        XCTAssertEqual(ExpectedSpeakers(storageValue: 0), .auto)
    }

    func test_displayName_isHumanReadable() {
        XCTAssertEqual(ExpectedSpeakers.auto.displayName, "Auto detect")
        XCTAssertEqual(ExpectedSpeakers.exact(1).displayName, "Solo (1 speaker)")
        XCTAssertEqual(ExpectedSpeakers.exact(3).displayName, "3 speakers")
    }

    func test_allCases_includesAutoAndCommonCounts() {
        let all = ExpectedSpeakers.allCases
        XCTAssertTrue(all.contains(.auto))
        XCTAssertTrue(all.contains(.exact(1)))
        XCTAssertTrue(all.contains(.exact(2)))
    }
}
