import Foundation

/// Maps each action item from `summary.json` to the transcript segment
/// it should highlight.
///
/// The naive approach — pin to the segment whose `[start, end)` contains
/// the action item's `timestamp` — produces spurious highlights because
/// Claude tends to round timestamps to the nearest minute, and the
/// segment that exact second falls in is often a filler word ("ไม่มี",
/// "อืม") rather than the substantive commitment. We compensate by:
///
/// 1. Resolving the action item's speaker name to a `SpeakerID`.
/// 2. Searching segments in a ±20s window around the timestamp.
/// 3. Filtering to segments by the same speaker.
/// 4. Picking the segment with the most content (longest text), with
///    closeness to the timestamp as tiebreaker.
/// 5. Falling back to the timestamp-only match when speaker can't be
///    resolved or no same-speaker segment is in the window — better to
///    over-pin near the right time than to drop the highlight entirely.
enum ActionItemMatcher {

    /// Window radius around an action item's timestamp, in seconds. Wide
    /// enough to absorb Claude's minute-rounding (which can be off by
    /// up to ~30s in the worst case) without bleeding into adjacent
    /// commitments. Tuned to the typical "1-3 action items per
    /// 5-minute span" density of meeting transcripts.
    static let windowRadius: TimeInterval = 20

    /// Build the segment-id → action-item lookup used by the transcript
    /// viewer. Segments not matched to any action item are absent from
    /// the returned dictionary.
    static func match(
        items: [ActionItem],
        segments: [TranscriptSegment],
        speakers: [Speaker],
        speakerProfiles: [SpeakerProfile]
    ) -> [TranscriptSegment.ID: ActionItem] {
        guard !items.isEmpty, !segments.isEmpty else { return [:] }
        let nameToID = buildNameLookup(speakers: speakers, profiles: speakerProfiles)
        var result: [TranscriptSegment.ID: ActionItem] = [:]
        for item in items {
            guard let t = item.timestampSeconds else { continue }
            let speakerID = nameToID[normalize(item.speaker)]
            if let segID = pickSegmentID(
                segments: segments,
                timestamp: t,
                speakerID: speakerID
            ) {
                result[segID] = item
            }
        }
        return result
    }

    // MARK: - Internals

    private static func pickSegmentID(
        segments: [TranscriptSegment],
        timestamp t: TimeInterval,
        speakerID: SpeakerID?
    ) -> TranscriptSegment.ID? {
        if let speakerID,
           let id = pickSameSpeakerInWindow(
               segments: segments,
               timestamp: t,
               speakerID: speakerID
           ) {
            return id
        }
        return pickContaining(segments: segments, timestamp: t)
    }

    /// Among same-speaker segments within ±`windowRadius` of `t`, pick
    /// the one with the most content (longest text). Ties broken by
    /// distance from `t` (closer wins). Returns nil when no same-
    /// speaker segment falls in the window — the caller falls back.
    private static func pickSameSpeakerInWindow(
        segments: [TranscriptSegment],
        timestamp t: TimeInterval,
        speakerID: SpeakerID
    ) -> TranscriptSegment.ID? {
        let lo = t - windowRadius
        let hi = t + windowRadius
        var best: TranscriptSegment?
        for seg in segments {
            // Segments are sorted by start; bail out once we're past
            // the right edge of the window.
            if seg.start > hi { break }
            if seg.end < lo { continue }
            if seg.speaker != speakerID { continue }
            guard let current = best else {
                best = seg
                continue
            }
            let segLen = seg.text.count
            let bestLen = current.text.count
            if segLen > bestLen {
                best = seg
            } else if segLen == bestLen {
                if abs(seg.start - t) < abs(current.start - t) {
                    best = seg
                }
            }
        }
        return best?.id
    }

    /// Original behavior: rightmost segment with `start <= t`, accepted
    /// only if `t < end` (i.e. `t` actually falls inside it). Used as
    /// the fallback when same-speaker matching fails.
    private static func pickContaining(
        segments: [TranscriptSegment],
        timestamp t: TimeInterval
    ) -> TranscriptSegment.ID? {
        var lo = 0
        var hi = segments.count - 1
        var best = -1
        while lo <= hi {
            let mid = (lo &+ hi) >> 1
            if segments[mid].start <= t {
                best = mid
                lo = mid &+ 1
            } else {
                hi = mid &- 1
            }
        }
        guard best >= 0 else { return nil }
        let seg = segments[best]
        return t < seg.end ? seg.id : nil
    }

    /// Build a `display-name → SpeakerID` map from the meeting's
    /// roster. Speaker profiles win over transcript-default names since
    /// they reflect the user's renames / attendee mappings, which is
    /// what Claude sees in the prompt's roster section.
    ///
    /// Maps "you" / "me" to `SpeakerID.me` so action items Claude
    /// attributed to the user (the speaker labeled "Me" in the
    /// transcript) resolve correctly.
    private static func buildNameLookup(
        speakers: [Speaker],
        profiles: [SpeakerProfile]
    ) -> [String: SpeakerID] {
        var map: [String: SpeakerID] = [:]
        for s in speakers {
            map[normalize(s.displayName)] = s.id
        }
        for p in profiles {
            map[normalize(p.displayName)] = p.id
        }
        // Claude's prompt rules say "use 'You' when the user committed
        // to the action" — bind both common spellings to the mic-side
        // speaker id.
        map["you"] = .me
        map["me"] = .me
        return map
    }

    private static func normalize(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
