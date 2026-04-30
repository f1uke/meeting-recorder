import XCTest
@testable import Meeting

final class CalendarMatcherTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_715_000_000)

    private func makeEvent(
        id: String = UUID().uuidString,
        title: String = "Event",
        startsIn minutes: Double,
        durationMin: Double = 30,
        conferenceURL: URL? = nil
    ) -> CalendarEvent {
        CalendarEvent(
            eventIdentifier: id,
            externalIdentifier: nil,
            title: title,
            startDate: now.addingTimeInterval(minutes * 60),
            endDate: now.addingTimeInterval((minutes + durationMin) * 60),
            location: nil,
            conferenceURL: conferenceURL,
            calendarName: "Work",
            organizer: nil,
            attendees: [],
            openInCalendarURL: nil
        )
    }

    // MARK: - score()

    func test_score_eventHappeningNow_scoresHigh() {
        let event = makeEvent(startsIn: -5, durationMin: 30)
        let score = CalendarMatcher.score(event: event, now: now)
        XCTAssertGreaterThanOrEqual(score.total, 100)
    }

    func test_score_eventStartingInTwoMinutes_scoresMidHigh() {
        let event = makeEvent(startsIn: 2)
        let score = CalendarMatcher.score(event: event, now: now)
        // 80 - 2*4 = 72
        XCTAssertEqual(score.total, 72, accuracy: 0.001)
    }

    func test_score_eventThatEnded_scoresZero() {
        let event = makeEvent(startsIn: -60, durationMin: 30) // ended 30 min ago
        let score = CalendarMatcher.score(event: event, now: now)
        XCTAssertEqual(score.total, 0)
    }

    func test_score_appUrlMatchAddsBoost() {
        let zoomURL = URL(string: "https://us02web.zoom.us/j/123")!
        let event = makeEvent(startsIn: 10, conferenceURL: zoomURL)
        let withZoom = CalendarMatcher.score(event: event, now: now, windowBundleID: "us.zoom.xos")
        let withoutZoom = CalendarMatcher.score(event: event, now: now, windowBundleID: nil)
        XCTAssertEqual(withZoom.total - withoutZoom.total, 30, accuracy: 0.001)
    }

    func test_score_unrelatedAppDoesNotBoost() {
        let zoomURL = URL(string: "https://us02web.zoom.us/j/123")!
        let event = makeEvent(startsIn: 10, conferenceURL: zoomURL)
        let withSafari = CalendarMatcher.score(event: event, now: now, windowBundleID: "com.apple.safari")
        let baseline = CalendarMatcher.score(event: event, now: now)
        // Safari isn't on the Zoom-host map, so no boost.
        XCTAssertEqual(withSafari.total, baseline.total, accuracy: 0.001)
    }

    // MARK: - bestMatch()

    func test_bestMatch_prefersHappeningNowOverUpcoming() {
        let happening = makeEvent(id: "now", title: "Now", startsIn: -5)
        let upcoming = makeEvent(id: "next", title: "Next", startsIn: 3)
        let result = CalendarMatcher.bestMatch(events: [upcoming, happening], now: now)
        XCTAssertEqual(result?.event.eventIdentifier, "now")
    }

    func test_bestMatch_appHintBreaksTieToCorrectMeeting() {
        // Two events starting in 10 min: one with Zoom URL, one without.
        // With a Zoom window selected, the Zoom event should win.
        let zoomURL = URL(string: "https://us02web.zoom.us/j/123")!
        let zoomEvent = makeEvent(id: "zoom", title: "Zoom", startsIn: 10, conferenceURL: zoomURL)
        let inPerson = makeEvent(id: "ip", title: "In-person", startsIn: 10, conferenceURL: nil)
        let result = CalendarMatcher.bestMatch(
            events: [inPerson, zoomEvent],
            now: now,
            windowBundleID: "us.zoom.xos"
        )
        XCTAssertEqual(result?.event.eventIdentifier, "zoom")
    }

    func test_bestMatch_returnsNilWhenAllEventsEnded() {
        let pastA = makeEvent(startsIn: -120, durationMin: 30)
        let pastB = makeEvent(startsIn: -60, durationMin: 30)
        let result = CalendarMatcher.bestMatch(events: [pastA, pastB], now: now)
        XCTAssertNil(result)
    }

    func test_bestMatch_emptyList_returnsNil() {
        let result = CalendarMatcher.bestMatch(events: [], now: now)
        XCTAssertNil(result)
    }
}
