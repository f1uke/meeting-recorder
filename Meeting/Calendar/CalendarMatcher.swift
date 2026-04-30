import Foundation

/// Pure-functional ranker for calendar events. Given a list of candidate
/// events, the current time, and optionally the bundle ID of the meeting
/// app the user is about to record, picks the event most likely to be
/// "the meeting they're recording right now."
///
/// Lives separately from `CalendarStore` so it has no EventKit dependency
/// and can be unit-tested with synthetic `CalendarEvent` values.
enum CalendarMatcher {
    struct Score: Equatable, Sendable {
        var total: Double
        /// Human-readable explanation of why this event was picked. Used
        /// by debug logs / future explainer UI; not user-facing yet.
        var reason: String
    }

    /// Pick the best event from `events` for "now," optionally
    /// boosted by a window app match. Returns nil if no event scores
    /// above zero (i.e. nothing is happening or starting imminently).
    static func bestMatch(
        events: [CalendarEvent],
        now: Date,
        windowBundleID: String? = nil
    ) -> (event: CalendarEvent, score: Score)? {
        let scored = events.map { event -> (CalendarEvent, Score) in
            (event, score(event: event, now: now, windowBundleID: windowBundleID))
        }
        // Tie-break: higher score, then earlier start (so a "now" event
        // beats a "starts in 2 min", and the earlier of two simultaneous
        // events wins).
        let best = scored
            .filter { $0.1.total > 0 }
            .max { lhs, rhs in
                if lhs.1.total != rhs.1.total { return lhs.1.total < rhs.1.total }
                return lhs.0.startDate > rhs.0.startDate
            }
        return best
    }

    static func score(
        event: CalendarEvent,
        now: Date,
        windowBundleID: String? = nil
    ) -> Score {
        var total: Double = 0
        var notes: [String] = []

        // Time component — peaks while the event is happening, ramps up
        // in the 15 minutes before, and decays for the next hour after
        // start. Past-end events get nothing.
        let secondsUntilStart = event.startDate.timeIntervalSince(now)
        let secondsAfterEnd = now.timeIntervalSince(event.endDate)

        if secondsAfterEnd > 0 {
            // Already over.
            return Score(total: 0, reason: "ended \(Int(secondsAfterEnd / 60))m ago")
        }

        if event.startDate <= now && now <= event.endDate {
            total += 100
            let minsIn = Int(now.timeIntervalSince(event.startDate) / 60)
            notes.append("happening now (\(minsIn)m in)")
        } else if secondsUntilStart >= 0 {
            let minsUntil = secondsUntilStart / 60
            switch minsUntil {
            case 0..<5:
                total += 80 - minsUntil * 4 // 80 → 60 over the 5 min window
                notes.append("starts in \(Int(minsUntil))m")
            case 5..<15:
                total += 50 - (minsUntil - 5) * 2 // 50 → 30 over the next 10 min
                notes.append("starts in \(Int(minsUntil))m")
            case 15..<60:
                total += 20 - (minsUntil - 15) / 5 // 20 → ~11 over 45 min
                notes.append("starts in \(Int(minsUntil))m")
            default:
                // Far-out events get a small floor so the matcher can still
                // pick "the next event" if asked, but it'll lose to
                // anything closer.
                total += 1
                notes.append("starts in \(Int(minsUntil))m")
            }
        }

        // App-match component — if we have a bundle ID for the chosen
        // window, boost events whose conference URL points at the same
        // service. This is what makes auto-detect "feel right" when the
        // user has back-to-back Zoom and Meet calls.
        if let bundleID = windowBundleID, let confURL = event.conferenceURL,
           appMatchesURL(bundleID: bundleID, url: confURL) {
            total += 30
            notes.append("\(bundleID) ↔ \(confURL.host ?? "url")")
        }

        return Score(total: total, reason: notes.joined(separator: ", "))
    }

    /// Lightweight bundle-id ↔ URL host correlation. Easy to extend.
    private static func appMatchesURL(bundleID: String, url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        let lowerBundle = bundleID.lowercased()
        let pairs: [(bundlePrefix: String, hostSuffixes: [String])] = [
            ("us.zoom",                ["zoom.us", "zoom.com"]),
            ("com.google.chrome",      ["meet.google.com"]),    // Meet often opens in Chrome
            ("com.google.meetings",    ["meet.google.com"]),
            ("com.apple.safari",       ["meet.google.com"]),
            ("com.microsoft.teams",    ["teams.microsoft.com", "teams.live.com"]),
            ("com.cisco.webex",        ["webex.com"]),
            ("com.hnc.discord",        ["discord.com", "discord.gg"]),
            ("com.tinyspeck.slackmacgap", ["slack.com"]),
        ]
        for pair in pairs where lowerBundle.hasPrefix(pair.bundlePrefix) {
            if pair.hostSuffixes.contains(where: { host == $0 || host.hasSuffix(".\($0)") }) {
                return true
            }
        }
        return false
    }
}
