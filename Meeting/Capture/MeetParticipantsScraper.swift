import Foundation
import AppKit
import ApplicationServices

/// Periodic AX scrape of Google Meet's video tile name overlays to record
/// who actually joined the meeting — surfaced in Library detail next to
/// the calendar invitee list. Useful when a meeting was invited via a
/// group email (which `EventKit` can't expand) so the calendar attendees
/// alone show one "group" entry instead of the actual people.
///
/// Tradeoffs:
/// - Only captures CURRENTLY-VISIBLE tiles. In big meetings the layout
///   shows roughly 8-12 tiles at once; people who never become an active
///   speaker may never get a tile and stay missing.
/// - Periodic re-scrape (default every 30s) accumulates names as the
///   layout rotates the active speaker — catches most people in a
///   typical meeting eventually.
/// - Email-only participants (whose Google display name didn't resolve)
///   are filtered out by the name-pattern check, since accepting
///   anything-with-an-@ would catch every email-shaped string in the
///   page (e.g. URL bar, history). The calendar.json sidecar still has
///   them.
@MainActor
final class MeetParticipantsCollector {
    private let pid: pid_t
    private var collected: Set<String> = []
    private var timer: Timer?

    init(pid: pid_t) {
        self.pid = pid
    }

    func start(interval: TimeInterval = 30) {
        guard AXIsProcessTrusted() else {
            NSLog("[Meeting/MeetParticipants] skipped: Accessibility not granted")
            return
        }
        // First scrape runs synchronously so the initial set is captured
        // immediately, not 30s into the recording.
        scrapeNow()
        let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scrapeNow() }
        }
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// All unique participant names captured so far, sorted alphabetically.
    var allParticipants: [String] {
        Array(collected).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func scrapeNow() {
        let names = MeetParticipantsScraper.scrape(pid: pid)
        let new = names.subtracting(collected)
        guard !new.isEmpty else { return }
        collected.formUnion(new)
        NSLog("[Meeting/MeetParticipants] +%d new (total %d): %@",
              new.count, collected.count,
              new.sorted().joined(separator: ", "))
    }
}

/// Stateless scraper — given a Chrome PID, returns the set of names
/// currently visible as Meet video tiles. The collector above wraps this
/// in a periodic timer; this enum is also useful for one-shot probes.
enum MeetParticipantsScraper {
    private static let maxDepth = 60

    static func scrape(pid: pid_t) -> Set<String> {
        let app = AXUIElementCreateApplication(pid)
        var names = Set<String>()
        for window in axChildren(app) {
            guard isMeetWindow(window) else { continue }
            walk(window, depth: 0, parents: [], names: &names)
        }
        return names
    }

    /// Roles whose subtree we exclude — they hold UI text that is not a
    /// participant name: tabs / toolbar / menus, hyperlinks (catches
    /// YouTube tiles that share the WebArea when Meet is in the same
    /// process), headings (page section titles, including the meeting
    /// name in Meet's own UI).
    private static let nonParticipantRoles: Set<String> = [
        "AXLink", "AXHeading", "AXMenu", "AXMenuBar",
        "AXToolbar", "AXTabGroup",
    ]

    private static func isMeetWindow(_ element: AXUIElement) -> Bool {
        guard let role = axString(element, kAXRoleAttribute as CFString),
              role == "AXWindow" else { return false }
        let title = axString(element, kAXTitleAttribute as CFString) ?? ""
        // Chrome window titles for Meet look like
        //   "Meet - <meeting name> - Microphone recording - Google Chrome ..."
        // PiP windows match the same pattern; both are walked.
        return title.hasPrefix("Meet -") || title.contains(" - Meet ")
    }

    private static func walk(
        _ element: AXUIElement,
        depth: Int,
        parents: [String],
        names: inout Set<String>
    ) {
        guard depth < maxDepth else { return }
        let role = axString(element, kAXRoleAttribute as CFString) ?? ""
        if role == "AXStaticText",
           let value = axString(element, kAXValueAttribute as CFString),
           looksLikeParticipantName(value),
           !parents.contains(where: nonParticipantRoles.contains) {
            names.insert(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        for child in axChildren(element) {
            walk(child, depth: depth + 1, parents: parents + [role], names: &names)
        }
    }

    /// Permissive but defensive — accepts 2-3 word strings that include at
    /// least one capitalized word; rejects emails, URLs, button text,
    /// status strings ("X joined", "Y has left"), chat snippets, stat
    /// readouts, and presenting badges. Tuned against a 42-person Meet on
    /// 2026-05-05 where the activity panel and chat sidebar leaked dozens
    /// of `AXStaticText` nodes ("Added 😯 reaction.", "Memory usage: 395 MB",
    /// "Drink Sirichai (Presenting)", "พี่ต่อเอา Template ไหนดีครับ").
    static func looksLikeParticipantName(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 3, t.count <= 60 else { return false }

        // Punctuation that real display names don't carry but UI strings,
        // chat messages, and stat readouts almost always do.
        let bannedChars: Set<Character> = [
            "@", "/", ":", "(", ")", "+", ".", ",", "?", "!",
        ]
        if t.contains(where: bannedChars.contains) { return false }
        // " - " separator (e.g. "Mobile team workload - Google Sheets").
        // Single hyphens stay allowed so names like "Anne-Marie" survive.
        if t.contains(" - ") { return false }

        // Digits — names don't have them.
        if t.unicodeScalars.contains(where: CharacterSet.decimalDigits.contains) {
            return false
        }
        // Emoji / pictograph symbols. Thai and CJK letters are *not* in
        // `.symbols`, so this only strips the emoji-bearing chat strings.
        if t.unicodeScalars.contains(where: CharacterSet.symbols.contains) {
            return false
        }

        // Multi-word ALL-CAPS phrases ("HISTORY IS ON", "SPACE UPDATE").
        if t.contains(" "), t == t.uppercased() { return false }

        let lc = t.lowercased()
        let badPrefixes = [
            "added ", "audio ", "click ", "close ", "getting ",
            "hide ", "history ", "join ", "leave ", "lower ",
            "memory ", "message ", "messages ", "mobile ", "mobility ",
            "more ", "mute ", "now ", "open ", "pin ", "raise ",
            "remove ", "send ", "show ", "space ", "switch ",
            "tap ", "this ", "turn ", "view ", "you ", "you'",
            "your ", "zoom ",
        ]
        if badPrefixes.contains(where: lc.hasPrefix) { return false }

        // Status / chat verbs that follow a name in a single AXStaticText
        // value, so we can't filter them out via prefix alone.
        let badSubstrings = [
            " joined", " left ", " has left", " reacted",
            " sent", " saved", " presenting",
        ]
        if badSubstrings.contains(where: lc.contains) { return false }

        // The team this app is built for uses 2-word First-Last Meet
        // display names exclusively. Anything else (single words, 3+
        // word strings, chat fragments like "Max สองคนละ iOS") is noise.
        let parts = t.split(separator: " ")
        guard parts.count == 2 else { return false }

        return parts.contains { $0.first?.isUppercase == true }
    }

    // MARK: - AX helpers

    private static func axString(_ e: AXUIElement, _ name: CFString) -> String? {
        var v: AnyObject?
        guard AXUIElementCopyAttributeValue(e, name, &v) == .success else { return nil }
        return v as? String
    }

    private static func axChildren(_ e: AXUIElement) -> [AXUIElement] {
        var v: AnyObject?
        guard AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &v) == .success else { return [] }
        return (v as? [AXUIElement]) ?? []
    }
}

// MARK: - Sidecar file

/// Persisted record of who Meet's UI showed as a participant during the
/// recording. Library detail merges this with `calendar.json` so groups
/// that EventKit couldn't expand still surface their actual members.
struct MeetParticipantsFile: Codable, Sendable, Equatable {
    static let filename = "meet_participants.json"
    static let currentVersion = 1

    let version: Int
    /// All distinct participant display names seen during the recording.
    /// Sorted case-insensitively for stable diffs across re-syncs.
    let participants: [String]

    init(participants: [String]) {
        self.version = Self.currentVersion
        self.participants = participants.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    static func read(from folder: URL) -> MeetParticipantsFile? {
        let url = folder.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    func write(to folder: URL) throws {
        let url = folder.appendingPathComponent(Self.filename)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
