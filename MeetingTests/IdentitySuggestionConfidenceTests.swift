import XCTest
@testable import Meeting

final class IdentitySuggestionConfidenceTests: XCTestCase {
    func test_threshold_maps_to50pct() {
        XCTAssertEqual(IdentityMatcher.confidencePercent(0.45), 50)
    }
    func test_perfect_maps_to99pct() {
        XCTAssertEqual(IdentityMatcher.confidencePercent(1.0), 99)
    }
    func test_belowThreshold_clamps_to50pct() {
        XCTAssertEqual(IdentityMatcher.confidencePercent(0.3), 50)
    }
    func test_aboveOne_clamps_to99pct() {
        XCTAssertEqual(IdentityMatcher.confidencePercent(1.5), 99)
    }
    func test_midpoint_isAbout75pct() {
        // (0.725 - 0.45) / 0.55 = 0.5 → 50 + 0.5*49 = 74
        XCTAssertEqual(IdentityMatcher.confidencePercent(0.725), 74)
    }
}
