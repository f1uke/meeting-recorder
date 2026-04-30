import XCTest
@testable import Meeting

final class CalendarEventFileTests: XCTestCase {
    func test_roundTrip_preservesAllFields() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let event = CalendarEvent(
            eventIdentifier: "evt-1",
            externalIdentifier: "ext-abc",
            title: "Q2 Roadmap Sync",
            startDate: Date(timeIntervalSince1970: 1_700_000_000),
            endDate: Date(timeIntervalSince1970: 1_700_001_800),
            location: "Conference Room A",
            conferenceURL: URL(string: "https://zoom.us/j/456"),
            calendarName: "Work",
            organizer: CalendarAttendee(
                displayName: "Pim",
                email: "pim@example.com",
                isMe: false,
                role: "chair"
            ),
            attendees: [
                CalendarAttendee(displayName: "Fluke", email: "fluke@example.com", isMe: true, role: "required"),
                CalendarAttendee(displayName: "Aon", email: nil, isMe: false, role: "optional"),
            ],
            openInCalendarURL: URL(string: "x-apple-calevent://evt-1")
        )

        try CalendarEventFile(event: event).write(to: folder)
        let restored = try CalendarEventFile.read(from: folder)

        XCTAssertEqual(restored.event, event)
    }

    func test_totalAttendeeCount_dedupesByEmail() {
        let event = CalendarEvent(
            eventIdentifier: "evt-2",
            externalIdentifier: nil,
            title: "Test",
            startDate: Date(),
            endDate: Date().addingTimeInterval(60),
            location: nil,
            conferenceURL: nil,
            calendarName: nil,
            organizer: CalendarAttendee(
                displayName: "Pim",
                email: "pim@example.com",
                isMe: false,
                role: nil
            ),
            attendees: [
                // Same email as organizer → dedupe.
                CalendarAttendee(displayName: "Pim S.", email: "pim@example.com", isMe: false, role: nil),
                CalendarAttendee(displayName: "Aon", email: "aon@example.com", isMe: false, role: nil),
            ],
            openInCalendarURL: nil
        )
        XCTAssertEqual(event.totalAttendeeCount, 2)
    }

    func test_totalAttendeeCount_noEmails_fallsBackToCount() {
        let event = CalendarEvent(
            eventIdentifier: "evt-3",
            externalIdentifier: nil,
            title: "Test",
            startDate: Date(),
            endDate: Date().addingTimeInterval(60),
            location: nil,
            conferenceURL: nil,
            calendarName: nil,
            organizer: nil,
            attendees: [
                CalendarAttendee(displayName: "A", email: nil, isMe: false, role: nil),
                CalendarAttendee(displayName: "B", email: nil, isMe: false, role: nil),
            ],
            openInCalendarURL: nil
        )
        XCTAssertEqual(event.totalAttendeeCount, 2)
    }

    func test_isHappeningNow_truthful() {
        let now = Date()
        let happening = CalendarEvent(
            eventIdentifier: "h",
            externalIdentifier: nil,
            title: "Now",
            startDate: now.addingTimeInterval(-60),
            endDate: now.addingTimeInterval(60),
            location: nil, conferenceURL: nil, calendarName: nil,
            organizer: nil, attendees: [], openInCalendarURL: nil
        )
        XCTAssertTrue(happening.isHappeningNow)

        let upcoming = CalendarEvent(
            eventIdentifier: "u",
            externalIdentifier: nil,
            title: "Soon",
            startDate: now.addingTimeInterval(60),
            endDate: now.addingTimeInterval(120),
            location: nil, conferenceURL: nil, calendarName: nil,
            organizer: nil, attendees: [], openInCalendarURL: nil
        )
        XCTAssertFalse(upcoming.isHappeningNow)
    }

    private func makeTempFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
