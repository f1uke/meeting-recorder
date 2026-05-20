import Foundation

/// Single source of truth for "this conference URL host belongs to this set
/// of apps." Lifted out of `CalendarMatcher` so the auto-record source
/// resolver and the matcher's scoring stay in sync.
enum ConferenceURLAppMap {

    struct AppEntry: Sendable {
        let bundleIDPrefix: String
        let hostSuffixes: [String]
        let displayName: String
        let preferredTitleSubstrings: [String]
    }

    static let entries: [AppEntry] = [
        AppEntry(
            bundleIDPrefix: "us.zoom",
            hostSuffixes: ["zoom.us", "zoom.com"],
            displayName: "Zoom",
            preferredTitleSubstrings: ["zoom meeting"]
        ),
        AppEntry(
            bundleIDPrefix: "com.google.chrome",
            hostSuffixes: ["meet.google.com"],
            displayName: "Google Meet",
            preferredTitleSubstrings: ["meet -", "meet \u{2014}", "google meet"]
        ),
        AppEntry(
            bundleIDPrefix: "com.google.meetings",
            hostSuffixes: ["meet.google.com"],
            displayName: "Google Meet",
            preferredTitleSubstrings: ["meet"]
        ),
        AppEntry(
            bundleIDPrefix: "com.apple.safari",
            hostSuffixes: ["meet.google.com"],
            displayName: "Google Meet",
            preferredTitleSubstrings: ["meet -", "meet \u{2014}", "google meet"]
        ),
        AppEntry(
            bundleIDPrefix: "com.microsoft.teams",
            hostSuffixes: ["teams.microsoft.com", "teams.live.com"],
            displayName: "Microsoft Teams",
            preferredTitleSubstrings: ["meeting"]
        ),
        AppEntry(
            bundleIDPrefix: "com.cisco.webex",
            hostSuffixes: ["webex.com"],
            displayName: "Webex",
            preferredTitleSubstrings: ["meeting"]
        ),
        AppEntry(
            bundleIDPrefix: "com.hnc.discord",
            hostSuffixes: ["discord.com", "discord.gg"],
            displayName: "Discord",
            preferredTitleSubstrings: []
        ),
        AppEntry(
            bundleIDPrefix: "com.tinyspeck.slackmacgap",
            hostSuffixes: ["slack.com"],
            displayName: "Slack",
            preferredTitleSubstrings: []
        ),
    ]

    /// All bundle-ID prefixes that could host a meeting hosted at `url`.
    /// Returns prefixes (not full identifiers) so callers can match against
    /// `bundleID.hasPrefix(...)` to catch helper processes.
    static func bundleIDPrefixes(for url: URL) -> [String] {
        guard let host = url.host?.lowercased() else { return [] }
        return entries
            .filter { entry in
                entry.hostSuffixes.contains { host == $0 || host.hasSuffix(".\($0)") }
            }
            .map { $0.bundleIDPrefix }
    }

    /// Existing `CalendarMatcher` helper, moved verbatim.
    static func appMatchesURL(bundleID: String, url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        let lower = bundleID.lowercased()
        for entry in entries where lower.hasPrefix(entry.bundleIDPrefix) {
            if entry.hostSuffixes.contains(where: { host == $0 || host.hasSuffix(".\($0)") }) {
                return true
            }
        }
        return false
    }

    /// Human-readable name ("Zoom", "Google Meet") for a bundle ID.
    /// Returns nil if the bundle isn't in our table.
    static func displayName(forBundleID bundleID: String) -> String? {
        let lower = bundleID.lowercased()
        return entries.first { lower.hasPrefix($0.bundleIDPrefix) }?.displayName
    }

    /// Substrings that, when present in an `SCWindow.title`, indicate the
    /// "real meeting window" rather than the app's home/contacts window.
    /// Lowercased. Empty array = no preference (any window of this app is fine).
    static func preferredTitleSubstrings(forBundleID bundleID: String) -> [String] {
        let lower = bundleID.lowercased()
        return entries.first { lower.hasPrefix($0.bundleIDPrefix) }?
            .preferredTitleSubstrings ?? []
    }
}
