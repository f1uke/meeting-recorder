import XCTest
@testable import Meeting

final class DoubleTapDetectorTests: XCTestCase {
    func test_twoQuickPresses_fire() {
        var d = DoubleTapDetector(window: 0.4)
        XCTAssertFalse(d.controlPressed(at: 0.0))
        XCTAssertTrue(d.controlPressed(at: 0.20))
    }

    func test_slowSecondPress_doesNotFire_butArmsNext() {
        var d = DoubleTapDetector(window: 0.4)
        XCTAssertFalse(d.controlPressed(at: 0.0))
        XCTAssertFalse(d.controlPressed(at: 0.9))   // too slow - becomes new first tap
        XCTAssertTrue(d.controlPressed(at: 1.0))    // quick follow-up fires
    }

    func test_otherInputBetween_resets() {
        var d = DoubleTapDetector(window: 0.4)
        XCTAssertFalse(d.controlPressed(at: 0.0))
        d.otherInputHappened()
        XCTAssertFalse(d.controlPressed(at: 0.1))   // first tap was cleared
    }

    func test_thirdPressAfterFire_startsFresh() {
        var d = DoubleTapDetector(window: 0.4)
        _ = d.controlPressed(at: 0.0)
        XCTAssertTrue(d.controlPressed(at: 0.2))    // fires, consumes both
        XCTAssertFalse(d.controlPressed(at: 0.3))   // next press is a new first tap
    }
}
