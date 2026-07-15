import XCTest
@testable import Meeting

/// `LibraryRowBuilder` flattens the Library's meetings into a single ordered
/// row list (headers interleaved with meeting rows). The behaviour these tests
/// lock in is the fix for the "two rows look selected at once" bug: a meeting
/// row's identity must be independent of which date-group it currently falls
/// in. The previous nested-ForEach design made identity hierarchical
/// (group + meeting.id), so when a meeting migrated between groups (e.g.
/// Today → This week after midnight + a rescan) while the window stayed open,
/// the LazyVStack recycled the slot and a previously-selected row kept its
/// blue highlight.
final class LibraryRowBuilderTests: XCTestCase {

    private let cal = Calendar.current
    private let now = Date(timeIntervalSince1970: 1_750_000_000)
    private var startOfToday: Date { cal.startOfDay(for: now) }

    private func record(_ name: String, at date: Date) -> MeetingRecord {
        MeetingRecord(
            folder: URL(fileURLWithPath: "/tmp/\(name)"),
            recordedAt: date,
            title: name,
            originalTitle: nil,
            duration: nil,
            speakerCount: 0,
            speakers: [],
            speakerProfiles: [],
            appName: nil,
            tags: [],
            starred: false,
            hasTranscript: false,
            summary: nil,
            calendarEvent: nil,
            meetParticipants: [],
            contextItems: []
        )
    }

    // MARK: - Grouping & ordering

    func test_buckets_inOrder_withHeadersOnlyForNonEmptyGroups() {
        let today = record("today", at: now)
        let week = record("week", at: startOfToday.addingTimeInterval(-3 * 86_400))

        let rows = LibraryRowBuilder.rows(for: [today, week], now: now)

        XCTAssertEqual(rows.map(\.id), [
            "header:Today", "meeting:today",
            "header:This week", "meeting:week",
        ])
        // Empty buckets contribute no header.
        XCTAssertFalse(rows.contains(.header("Yesterday")))
        XCTAssertFalse(rows.contains(.header("Earlier")))
    }

    func test_everyMeetingAppearsExactlyOnce_withGloballyUniqueIDs() {
        let recs = [
            record("a", at: now),                                            // Today
            record("b", at: startOfToday.addingTimeInterval(-3600)),         // Yesterday
            record("c", at: startOfToday.addingTimeInterval(-3 * 86_400)),   // This week
            record("d", at: startOfToday.addingTimeInterval(-30 * 86_400)),  // Earlier
        ]

        let rows = LibraryRowBuilder.rows(for: recs, now: now)

        let meetingIDs = rows.compactMap { row -> String? in
            if case let .meeting(m) = row { return m.id }
            return nil
        }
        XCTAssertEqual(meetingIDs.sorted(), ["a", "b", "c", "d"])   // each exactly once
        XCTAssertEqual(Set(rows.map(\.id)).count, rows.count)       // all row ids unique
    }

    // MARK: - Regression guard

    /// A meeting's row identity stays the same as it migrates between
    /// date-groups over time — the property that prevents the stale-highlight
    /// bug. The group header changes; the meeting row's id does not.
    func test_meetingRowID_isStable_acrossGroupMigration() {
        let m = record("m", at: now)

        let asToday = LibraryRowBuilder.rows(for: [m], now: now)
        // Same meeting, evaluated 3 days later → now falls into "This week".
        let asThisWeek = LibraryRowBuilder.rows(for: [m], now: now.addingTimeInterval(3 * 86_400))

        XCTAssertEqual(asToday.first, .header("Today"))
        XCTAssertEqual(asThisWeek.first, .header("This week"))

        XCTAssertEqual(meetingRowID(in: asToday), "meeting:m")
        XCTAssertEqual(meetingRowID(in: asThisWeek), "meeting:m")
    }

    private func meetingRowID(in rows: [LibraryRowItem]) -> String? {
        rows.first { if case .meeting = $0 { return true } else { return false } }?.id
    }
}
