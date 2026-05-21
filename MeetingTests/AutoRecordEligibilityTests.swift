import XCTest
@testable import Meeting

final class AutoRecordEligibilityTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let calID = "cal-work"

    private func event(
        id: String = "evt-1",
        calID: String? = "cal-work",
        startOffset: TimeInterval = 60,
        endOffset: TimeInterval = 30 * 60,
        attendees: [CalendarAttendee] = []
    ) -> CalendarEvent {
        CalendarEvent(
            eventIdentifier: id,
            externalIdentifier: nil,
            title: "Test",
            startDate: now.addingTimeInterval(startOffset),
            endDate: now.addingTimeInterval(endOffset),
            location: nil,
            conferenceURL: URL(string: "https://zoom.us/j/1"),
            calendarName: "Work",
            calendarIdentifier: calID,
            organizer: nil,
            attendees: attendees,
            openInCalendarURL: nil
        )
    }

    func test_eligible_happyPath() {
        let prefs = AutoRecordEligibilityPrefs(masterEnabled: true, enabledCalendarIDs: [calID])
        XCTAssertTrue(AutoRecordEligibility.eligible(
            event: event(), prefs: prefs, suppressedIDs: [], now: now))
    }

    func test_masterDisabled_returnsFalse() {
        let prefs = AutoRecordEligibilityPrefs(masterEnabled: false, enabledCalendarIDs: [calID])
        XCTAssertFalse(AutoRecordEligibility.eligible(
            event: event(), prefs: prefs, suppressedIDs: [], now: now))
    }

    func test_unselectedCalendar_returnsFalse() {
        let prefs = AutoRecordEligibilityPrefs(masterEnabled: true, enabledCalendarIDs: ["other"])
        XCTAssertFalse(AutoRecordEligibility.eligible(
            event: event(), prefs: prefs, suppressedIDs: [], now: now))
    }

    func test_eventWithoutCalendarIdentifier_returnsFalse() {
        let prefs = AutoRecordEligibilityPrefs(masterEnabled: true, enabledCalendarIDs: [calID])
        XCTAssertFalse(AutoRecordEligibility.eligible(
            event: event(calID: nil), prefs: prefs, suppressedIDs: [], now: now))
    }

    func test_suppressedID_returnsFalse() {
        let prefs = AutoRecordEligibilityPrefs(masterEnabled: true, enabledCalendarIDs: [calID])
        XCTAssertFalse(AutoRecordEligibility.eligible(
            event: event(id: "evt-x"), prefs: prefs, suppressedIDs: ["evt-x"], now: now))
    }

    func test_eventAlreadyEnded_returnsFalse() {
        let prefs = AutoRecordEligibilityPrefs(masterEnabled: true, enabledCalendarIDs: [calID])
        let past = event(startOffset: -60 * 60, endOffset: -30 * 60)
        XCTAssertFalse(AutoRecordEligibility.eligible(
            event: past, prefs: prefs, suppressedIDs: [], now: now))
    }

    func test_declinedByMe_returnsFalse() {
        let me = CalendarAttendee(
            displayName: "Me", email: "me@x", isMe: true,
            role: "required", status: "declined")
        let prefs = AutoRecordEligibilityPrefs(masterEnabled: true, enabledCalendarIDs: [calID])
        XCTAssertFalse(AutoRecordEligibility.eligible(
            event: event(attendees: [me]), prefs: prefs, suppressedIDs: [], now: now))
    }

    func test_declinedBySomeoneElse_returnsTrue() {
        let other = CalendarAttendee(
            displayName: "Other", email: "o@x", isMe: false,
            role: "required", status: "declined")
        let prefs = AutoRecordEligibilityPrefs(masterEnabled: true, enabledCalendarIDs: [calID])
        XCTAssertTrue(AutoRecordEligibility.eligible(
            event: event(attendees: [other]), prefs: prefs, suppressedIDs: [], now: now))
    }
}
