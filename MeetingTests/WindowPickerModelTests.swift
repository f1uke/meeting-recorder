import XCTest
import ScreenCaptureKit
@testable import Meeting

@MainActor
final class WindowPickerModelTests: XCTestCase {
    func test_selectedSource_nil_byDefault() {
        let model = WindowPickerModel()
        XCTAssertNil(model.selectedSource)
        XCTAssertNil(model.selectedCaptureSource)
    }

    func test_selectedSource_retained_whenDisplayStillPresent() {
        let model = WindowPickerModel()
        let mainID = CGMainDisplayID()
        model._seedForTests(displayIDs: [mainID])
        model.selectedSource = .display(mainID)
        XCTAssertEqual(model.selectedSource, .display(mainID))
    }

    func test_selectedSource_clearedWhenDisplayDisappears() {
        let model = WindowPickerModel()
        let mainID = CGMainDisplayID()
        model._seedForTests(displayIDs: [mainID])
        model.selectedSource = .display(mainID)

        // Display unplugged on a subsequent refresh.
        model._seedForTests(displayIDs: [])
        XCTAssertNil(model.selectedSource,
                     "selection should clear when its display vanishes")
    }

    func test_selectedSource_clearedWhenWindowDisappears() {
        let model = WindowPickerModel()
        let winID: CGWindowID = 0xCAFE
        model._seedForTests(windowIDs: [winID])
        model.selectedSource = .window(winID)

        model._seedForTests(windowIDs: [])
        XCTAssertNil(model.selectedSource,
                     "selection should clear when its window vanishes")
    }
}
