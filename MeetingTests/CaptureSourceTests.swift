import XCTest
import ScreenCaptureKit
@testable import Meeting

final class CaptureSourceTests: XCTestCase {
    func test_displayLabel_primary_includesSuffix() {
        let mainID = CGMainDisplayID()
        let label = CaptureSource.displayLabel(displayID: mainID)
        XCTAssertTrue(label.hasSuffix(" (primary)"),
                      "primary display should suffix '(primary)', got: \(label)")
    }

    func test_displayLabel_unknownID_fallsBackToIndex() {
        let bogusID: CGDirectDisplayID = 0xDEADBEEF
        let label = CaptureSource.displayLabel(displayID: bogusID)
        XCTAssertTrue(label.hasPrefix("Display "),
                      "unknown displayID should fall back to 'Display N', got: \(label)")
    }
}
