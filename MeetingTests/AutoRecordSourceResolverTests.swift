import XCTest
@testable import Meeting

final class AutoRecordSourceResolverTests: XCTestCase {

    func test_subtitle_noConferenceURL_describesDisplay() {
        let line = AutoRecordSourceResolver.subtitleForDisplayFallback(
            event: makeEvent(url: nil),
            displayName: "Display 1 (primary)"
        )
        XCTAssertEqual(line, "Recording Display 1 (primary)")
    }

    func test_subtitle_withConferenceURL_butNoWindow_includesAppName() {
        let url = URL(string: "https://zoom.us/j/1")!
        let line = AutoRecordSourceResolver.subtitleForDisplayFallback(
            event: makeEvent(url: url),
            displayName: "Display 1 (primary)"
        )
        XCTAssertEqual(line, "Recording Display 1 (primary) — couldn't find Zoom window")
    }

    func test_subtitle_withMatchedWindow_usesAppAndAttendeeCount() {
        let line = AutoRecordSourceResolver.subtitleForMatchedWindow(
            displayName: "Zoom",
            attendeeCount: 6
        )
        XCTAssertEqual(line, "Zoom · 6 attendees")
    }

    func test_subtitle_withMatchedWindow_zeroAttendees_omitsCount() {
        let line = AutoRecordSourceResolver.subtitleForMatchedWindow(
            displayName: "Zoom",
            attendeeCount: 0
        )
        XCTAssertEqual(line, "Zoom")
    }

    func test_pickBestWindow_prefersPreferredTitleSubstring() {
        let candidates: [AutoRecordSourceResolver.WindowCandidate] = [
            .init(title: "Zoom", area: 1_000_000),       // home window, huge
            .init(title: "Zoom Meeting", area: 500_000), // meeting window
        ]
        let best = AutoRecordSourceResolver.pickBest(
            candidates: candidates,
            preferredSubstrings: ["zoom meeting"],
            eventTitleHint: nil
        )
        XCTAssertEqual(best?.title, "Zoom Meeting")
    }

    func test_pickBestWindow_prefersEventTitleHint() {
        let candidates: [AutoRecordSourceResolver.WindowCandidate] = [
            .init(title: "Gmail — Inbox", area: 800_000),
            .init(title: "Q2 Roadmap Sync — Google Meet", area: 600_000),
        ]
        let best = AutoRecordSourceResolver.pickBest(
            candidates: candidates,
            preferredSubstrings: ["meet -", "meet \u{2014}"],
            eventTitleHint: "Q2 Roadmap Sync"
        )
        XCTAssertEqual(best?.title, "Q2 Roadmap Sync — Google Meet")
    }

    func test_pickBestWindow_fallsBackToLargestArea() {
        let candidates: [AutoRecordSourceResolver.WindowCandidate] = [
            .init(title: "Small", area: 100),
            .init(title: "Big", area: 500),
            .init(title: "Mid", area: 300),
        ]
        let best = AutoRecordSourceResolver.pickBest(
            candidates: candidates,
            preferredSubstrings: [],
            eventTitleHint: nil
        )
        XCTAssertEqual(best?.title, "Big")
    }

    func test_pickBestWindow_emptyCandidates_returnsNil() {
        let best = AutoRecordSourceResolver.pickBest(
            candidates: [],
            preferredSubstrings: [],
            eventTitleHint: nil
        )
        XCTAssertNil(best)
    }

    // MARK: - helpers

    private func makeEvent(url: URL?) -> CalendarEvent {
        CalendarEvent(
            eventIdentifier: "e",
            externalIdentifier: nil,
            title: "T",
            startDate: Date(),
            endDate: Date().addingTimeInterval(60),
            location: nil,
            conferenceURL: url,
            calendarName: nil,
            calendarIdentifier: nil,
            organizer: nil,
            attendees: [],
            openInCalendarURL: nil
        )
    }
}
