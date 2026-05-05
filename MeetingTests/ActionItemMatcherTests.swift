import XCTest
@testable import Meeting

final class ActionItemMatcherTests: XCTestCase {

    // MARK: - Filler-skip behaviour (the user's reported case)

    func test_match_skipsShortFillerForLongerSameSpeakerSegment() {
        // Den says "ไม่มี" (filler) at 15:00, then the real action-item
        // content at 15:01 — Claude rounded the timestamp to 15:00, so
        // the naive containing-segment match would land on "ไม่มี".
        let den = SpeakerID(rawValue: "speaker_0")
        let segments: [TranscriptSegment] = [
            seg(id: "1", start: 14 * 60 + 54, end: 14 * 60 + 58, speaker: den, text: "ส่วน เอ่อ ข้อ 3 ครับ"),
            seg(id: "2", start: 15 * 60, end: 15 * 60 + 1, speaker: den, text: "ไม่มี"),
            seg(id: "3", start: 15 * 60 + 1, end: 15 * 60 + 8, speaker: den, text: "เวลาที่นัดทีมก็เลย เดี๋ยวสัปดาห์นี้ มานัดกับทีมคุยกันอีกทีนึงครับ"),
        ]
        let items = [
            ActionItem(speaker: "Den", text: "Schedule team sync next week", timestamp: "15:00")
        ]
        let map = ActionItemMatcher.match(
            items: items,
            segments: segments,
            speakers: [Speaker(id: den, displayName: "Den")],
            speakerProfiles: []
        )
        XCTAssertEqual(map[seg(id: "3").id], items[0], "should snap to the contentful segment")
        XCTAssertNil(map[seg(id: "2").id], "filler segment should not be highlighted")
    }

    // MARK: - Speaker filtering

    func test_match_picksSameSpeakerEvenWhenWrongSpeakerSitsAtTimestamp() {
        // Action item attributed to Den at 15:00, but the segment
        // containing 15:00 is Tor's. Den's nearby segment should win.
        let den = SpeakerID(rawValue: "speaker_0")
        let tor = SpeakerID(rawValue: "speaker_1")
        let segments: [TranscriptSegment] = [
            seg(id: "1", start: 14 * 60 + 50, end: 14 * 60 + 55, speaker: den, text: "เดี๋ยวผมจะลองทำดู คาดว่าเสร็จศุกร์"),
            seg(id: "2", start: 14 * 60 + 58, end: 15 * 60 + 5, speaker: tor, text: "โอเคครับ"),
        ]
        let items = [
            ActionItem(speaker: "Den", text: "Try the approach by Friday", timestamp: "15:00")
        ]
        let map = ActionItemMatcher.match(
            items: items,
            segments: segments,
            speakers: [
                Speaker(id: den, displayName: "Den"),
                Speaker(id: tor, displayName: "Tor"),
            ],
            speakerProfiles: []
        )
        XCTAssertEqual(map[seg(id: "1").id]?.text, items[0].text)
        XCTAssertNil(map[seg(id: "2").id], "wrong-speaker segment must not be picked")
    }

    // MARK: - "You" → .me resolution

    func test_match_resolvesYouToMicSpeaker() {
        let other = SpeakerID(rawValue: "speaker_0")
        let segments: [TranscriptSegment] = [
            seg(id: "1", start: 5 * 60, end: 5 * 60 + 4, speaker: other, text: "ไม่มีอะไรเพิ่มเติมครับ"),
            seg(id: "2", start: 5 * 60 + 5, end: 5 * 60 + 12, speaker: .me, text: "ผมจะส่งสไลด์ให้ทีมคืนนี้"),
        ]
        let items = [
            ActionItem(speaker: "You", text: "Send slide deck tonight", timestamp: "5:00")
        ]
        let map = ActionItemMatcher.match(
            items: items,
            segments: segments,
            speakers: [
                Speaker(id: .me, displayName: "Me"),
                Speaker(id: other, displayName: "Tar"),
            ],
            speakerProfiles: []
        )
        XCTAssertEqual(map[seg(id: "2").id], items[0])
    }

    // MARK: - Fallback when speaker doesn't resolve

    func test_match_fallsBackToContainingSegmentForUnknownSpeaker() {
        // Claude attributed the action to "Mystery" — not in the roster.
        // The matcher should fall through to the containing-segment
        // behavior so we don't drop the highlight entirely.
        let den = SpeakerID(rawValue: "speaker_0")
        let segments: [TranscriptSegment] = [
            seg(id: "1", start: 60, end: 70, speaker: den, text: "เดี๋ยวผมรับไปดู"),
        ]
        let items = [
            ActionItem(speaker: "Mystery", text: "Investigate", timestamp: "01:05")
        ]
        let map = ActionItemMatcher.match(
            items: items,
            segments: segments,
            speakers: [Speaker(id: den, displayName: "Den")],
            speakerProfiles: []
        )
        XCTAssertEqual(map[seg(id: "1").id], items[0])
    }

    // MARK: - No match when speaker resolves but not in window

    func test_match_returnsEmptyWhenNoSameSpeakerInWindowAndNoContaining() {
        // Den's only segment is far outside the ±20s window AND there's
        // no segment containing the timestamp — nothing should be
        // highlighted.
        let den = SpeakerID(rawValue: "speaker_0")
        let tor = SpeakerID(rawValue: "speaker_1")
        let segments: [TranscriptSegment] = [
            seg(id: "1", start: 0, end: 30, speaker: den, text: "early Den content"),
            seg(id: "2", start: 31, end: 60, speaker: tor, text: "Tor middle"),
        ]
        let items = [
            ActionItem(speaker: "Den", text: "...", timestamp: "10:00")
        ]
        let map = ActionItemMatcher.match(
            items: items,
            segments: segments,
            speakers: [
                Speaker(id: den, displayName: "Den"),
                Speaker(id: tor, displayName: "Tor"),
            ],
            speakerProfiles: []
        )
        XCTAssertTrue(map.isEmpty)
    }

    // MARK: - Tiebreak by closeness when text length is equal

    func test_match_tiebreaksByDistanceFromTimestamp() {
        let den = SpeakerID(rawValue: "speaker_0")
        // Two same-speaker segments with identical text length; the one
        // closer to t=300 should win.
        let segments: [TranscriptSegment] = [
            seg(id: "far", start: 285, end: 290, speaker: den, text: "abcdefghij"),
            seg(id: "near", start: 298, end: 304, speaker: den, text: "abcdefghij"),
        ]
        let items = [
            ActionItem(speaker: "Den", text: "...", timestamp: "5:00")
        ]
        let map = ActionItemMatcher.match(
            items: items,
            segments: segments,
            speakers: [Speaker(id: den, displayName: "Den")],
            speakerProfiles: []
        )
        XCTAssertEqual(map.count, 1)
        XCTAssertNotNil(map[seg(id: "near").id])
    }

    // MARK: - SpeakerProfile renames win over transcript labels

    func test_match_resolvesProfileDisplayNameOverridingTranscriptLabel() {
        // Transcript carries a generic "Speaker 1" label, but the user
        // renamed them to "Pim" — Claude saw "Pim" in the prompt
        // roster, so the matcher must resolve "Pim" → that speaker id.
        let speakerID = SpeakerID(rawValue: "speaker_1")
        let segments: [TranscriptSegment] = [
            seg(id: "1", start: 60, end: 70, speaker: speakerID, text: "ผมจะลองคุยกับทีมก่อน")
        ]
        let items = [
            ActionItem(speaker: "Pim", text: "Talk to the team", timestamp: "01:05")
        ]
        let map = ActionItemMatcher.match(
            items: items,
            segments: segments,
            speakers: [Speaker(id: speakerID, displayName: "Speaker 1")],
            speakerProfiles: [
                SpeakerProfile(id: speakerID, displayName: "Pim")
            ]
        )
        XCTAssertEqual(map[seg(id: "1").id], items[0])
    }

    // MARK: - Helpers

    /// Build a TranscriptSegment with sane defaults for tests where
    /// only id matters (e.g. asserting on the lookup keys).
    private func seg(
        id: String,
        start: TimeInterval = 0,
        end: TimeInterval = 0,
        speaker: SpeakerID = .me,
        text: String = ""
    ) -> TranscriptSegment {
        let uuid = idCache.value(for: id)
        return TranscriptSegment(
            id: uuid,
            start: start,
            end: end,
            speaker: speaker,
            text: text,
            source: .meetingOutput
        )
    }

    /// Stable string-keyed UUIDs so `seg(id: "1")` returns the same id
    /// across calls within a single test (we use `id` to look up the
    /// matcher's output in assertions).
    private let idCache = IDCache()

    private final class IDCache {
        private var map: [String: UUID] = [:]
        func value(for key: String) -> UUID {
            if let v = map[key] { return v }
            let v = UUID()
            map[key] = v
            return v
        }
    }
}
