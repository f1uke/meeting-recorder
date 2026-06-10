import XCTest
@testable import Meeting

/// The video-retention sweep must trash only the videos of meetings older
/// than the configured window, always keeping starred meetings and never
/// touching anything when retention is off. `expiredVideoFolders` is the
/// pure selection step — exercised here without touching disk.
final class VideoRetentionPruneTests: XCTestCase {

    private static let now = Date(timeIntervalSince1970: 1_750_000_000)

    /// Build a bare MeetingRecord with only the fields the sweep reads
    /// (folder, recordedAt, starred); everything else is stubbed empty.
    private func record(_ name: String, ageDays: Double, starred: Bool = false) -> MeetingRecord {
        MeetingRecord(
            folder: URL(fileURLWithPath: "/tmp/\(name)"),
            recordedAt: Self.now.addingTimeInterval(-ageDays * 86_400),
            title: name,
            originalTitle: nil,
            duration: nil,
            speakerCount: 0,
            speakers: [],
            speakerProfiles: [],
            appName: nil,
            tags: [],
            starred: starred,
            hasTranscript: false,
            summary: nil,
            calendarEvent: nil,
            meetParticipants: [],
            contextItems: []
        )
    }

    private func names(_ urls: [URL]) -> Set<String> {
        Set(urls.map { $0.lastPathComponent })
    }

    // MARK: - Off

    func test_keepForever_selectsNothing_evenForAncientMeetings() {
        let records = [record("old", ageDays: 365), record("ancient", ageDays: 9999)]
        let expired = MeetingsLibrary.expiredVideoFolders(
            in: records, retention: .keepForever, now: Self.now
        )
        XCTAssertTrue(expired.isEmpty)
    }

    // MARK: - Age threshold

    func test_days7_selectsOnlyMeetingsOlderThanSevenDays() {
        let records = [
            record("fresh", ageDays: 1),
            record("sixDays", ageDays: 6),
            record("eightDays", ageDays: 8),
            record("month", ageDays: 30),
        ]
        let expired = MeetingsLibrary.expiredVideoFolders(
            in: records, retention: .days7, now: Self.now
        )
        XCTAssertEqual(names(expired), ["eightDays", "month"])
    }

    func test_exactlyAtCutoff_isNotExpired() {
        // recordedAt == cutoff → strict `<` keeps it.
        let records = [record("borderline", ageDays: 3)]
        let expired = MeetingsLibrary.expiredVideoFolders(
            in: records, retention: .days3, now: Self.now
        )
        XCTAssertTrue(expired.isEmpty)
    }

    // MARK: - Starred exemption

    func test_starredMeetings_areNeverSelected() {
        let records = [
            record("oldStarred", ageDays: 60, starred: true),
            record("oldPlain", ageDays: 60),
        ]
        let expired = MeetingsLibrary.expiredVideoFolders(
            in: records, retention: .days14, now: Self.now
        )
        XCTAssertEqual(names(expired), ["oldPlain"])
    }
}
