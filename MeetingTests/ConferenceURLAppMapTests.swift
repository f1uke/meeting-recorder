import XCTest
@testable import Meeting

final class ConferenceURLAppMapTests: XCTestCase {

    func test_bundleIDs_forZoomURL_returnsZoomPrefix() {
        let url = URL(string: "https://us02web.zoom.us/j/123")!
        let result = ConferenceURLAppMap.bundleIDPrefixes(for: url)
        XCTAssertTrue(result.contains("us.zoom"))
    }

    func test_bundleIDs_forMeetURL_returnsAllBrowserPrefixes() {
        let url = URL(string: "https://meet.google.com/abc-defg-hij")!
        let result = Set(ConferenceURLAppMap.bundleIDPrefixes(for: url))
        XCTAssertTrue(result.contains("com.google.chrome"))
        XCTAssertTrue(result.contains("com.apple.safari"))
        XCTAssertTrue(result.contains("com.google.meetings"))
    }

    func test_bundleIDs_forUnknownURL_returnsEmpty() {
        let url = URL(string: "https://example.com/meeting")!
        XCTAssertTrue(ConferenceURLAppMap.bundleIDPrefixes(for: url).isEmpty)
    }

    func test_appMatchesURL_zoomBundle_matchesZoomURL() {
        let url = URL(string: "https://zoom.us/j/123")!
        XCTAssertTrue(ConferenceURLAppMap.appMatchesURL(bundleID: "us.zoom.xos", url: url))
    }

    func test_appMatchesURL_chromeBundle_matchesMeetURL() {
        let url = URL(string: "https://meet.google.com/xyz")!
        XCTAssertTrue(ConferenceURLAppMap.appMatchesURL(bundleID: "com.google.Chrome", url: url))
    }

    func test_appMatchesURL_wrongPair_returnsFalse() {
        let url = URL(string: "https://meet.google.com/xyz")!
        XCTAssertFalse(ConferenceURLAppMap.appMatchesURL(bundleID: "us.zoom.xos", url: url))
    }

    func test_displayName_forZoomBundle_returnsZoom() {
        XCTAssertEqual(ConferenceURLAppMap.displayName(forBundleID: "us.zoom.xos"), "Zoom")
    }

    func test_preferredTitleSubstrings_forZoom_includesZoomMeeting() {
        let result = ConferenceURLAppMap.preferredTitleSubstrings(forBundleID: "us.zoom.xos")
        XCTAssertTrue(result.contains { $0.lowercased().contains("zoom meeting") })
    }
}
