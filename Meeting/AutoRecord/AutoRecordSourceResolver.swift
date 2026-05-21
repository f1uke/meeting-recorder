import Foundation
import ScreenCaptureKit
import AppKit

/// Returned by `AutoRecordSourceResolving.resolve` — lives at file scope so
/// the protocol is self-contained and conformers don't have to import the
/// concrete `AutoRecordSourceResolver` type.
///
/// Marked `@unchecked Sendable` because `CaptureSource` wraps `SCWindow` /
/// `SCDisplay` (non-Sendable ObjC reference types). All callers run on
/// `@MainActor`, so cross-isolation transfer doesn't actually occur; the
/// annotation only exists to satisfy the `Sendable` constraint on the
/// protocol — matches the project's `KitBox`/`DiarizerBox` pattern.
enum AutoRecordResolveResult: @unchecked Sendable {
    case source(CaptureSource, subtitle: String)
    case skip(reason: String)
}

/// Async protocol so `AutoRecordScheduler` can be tested with a stub
/// resolver that doesn't touch ScreenCaptureKit.
protocol AutoRecordSourceResolving: Sendable {
    func resolve(
        event: CalendarEvent,
        fallback: AutoRecordSourceFallback
    ) async -> AutoRecordResolveResult
}

/// Concrete implementation. Produces a `CaptureSource` + subtitle for the
/// countdown panel, or a `.skip` directive when the user picked the skip
/// fallback and no matching window exists.
struct AutoRecordSourceResolver: AutoRecordSourceResolving {

    /// Small value type the pure tie-break helper operates on, decoupled
    /// from the real `SCWindow` which has no public init.
    struct WindowCandidate {
        let title: String
        let area: Double
    }

    func resolve(
        event: CalendarEvent,
        fallback: AutoRecordSourceFallback
    ) async -> AutoRecordResolveResult {
        // 1. No conference URL → primary display.
        guard let url = event.conferenceURL else {
            return await displayFallbackResult(event: event, fallback: fallback)
        }

        // 2. URL → expected bundle ID prefixes.
        let prefixes = ConferenceURLAppMap.bundleIDPrefixes(for: url).map { $0.lowercased() }
        guard !prefixes.isEmpty else {
            return await displayFallbackResult(event: event, fallback: fallback)
        }

        // 3. Query windows.
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                true, onScreenWindowsOnly: true
            )
        } catch {
            return await displayFallbackResult(event: event, fallback: fallback)
        }

        // 4. Filter by bundle prefix.
        let matchingWindows = content.windows.filter { window in
            guard let bundleID = window.owningApplication?.bundleIdentifier else {
                return false
            }
            let lowerBundleID = bundleID.lowercased()
            return prefixes.contains { lowerBundleID.hasPrefix($0) }
        }

        if matchingWindows.isEmpty {
            return await displayFallbackResult(event: event, fallback: fallback, content: content)
        }

        // 5. Tie-break — union preferred substrings across all matched bundles
        // so that, e.g., Chrome AND Safari windows for meet.google.com are all
        // scored with the correct preferred-title hints.
        let bundlesInResults = Set(matchingWindows.compactMap { $0.owningApplication?.bundleIdentifier })
        let preferredSubstrings = Array(Set(
            bundlesInResults.flatMap { ConferenceURLAppMap.preferredTitleSubstrings(forBundleID: $0) }
        ))
        // Keep the first window's bundle ID only for the display-name lookup;
        // in practice all bundles for a given host resolve to the same name.
        let displayBundle = matchingWindows.first?.owningApplication?.bundleIdentifier ?? ""

        let candidates = matchingWindows.map { window in
            let area = Double(window.frame.width) * Double(window.frame.height)
            return WindowCandidate(title: window.title ?? "", area: area)
        }
        guard let best = Self.pickBest(
            candidates: candidates,
            preferredSubstrings: preferredSubstrings,
            eventTitleHint: event.title
        ) else {
            return await displayFallbackResult(event: event, fallback: fallback, content: content)
        }

        // Map the chosen candidate back to its SCWindow by title + area.
        let chosen = matchingWindows.first { w in
            let wTitle = w.title ?? ""
            let wArea = Double(w.frame.width) * Double(w.frame.height)
            return wTitle == best.title && wArea == best.area
        } ?? matchingWindows[0]

        let displayName = ConferenceURLAppMap
            .displayName(forBundleID: displayBundle) ?? "Meeting"
        let subtitle = Self.subtitleForMatchedWindow(
            displayName: displayName,
            attendeeCount: event.totalAttendeeCount
        )
        return .source(.window(chosen), subtitle: subtitle)
    }

    // MARK: - Pure helpers (testable)

    static func pickBest(
        candidates: [WindowCandidate],
        preferredSubstrings: [String],
        eventTitleHint: String?
    ) -> WindowCandidate? {
        guard !candidates.isEmpty else { return nil }
        let lowerHint = eventTitleHint?.lowercased()

        // Score = preferred-substring match (high) + event-title hint match
        // (medium) + area (low, used as a tiebreaker).
        func score(_ c: WindowCandidate) -> Double {
            let lowerTitle = c.title.lowercased()
            var s: Double = 0
            if preferredSubstrings.contains(where: { lowerTitle.contains($0) }) {
                s += 1_000_000
            }
            if let hint = lowerHint, !hint.isEmpty, lowerTitle.contains(hint) {
                s += 500_000
            }
            s += c.area / 1_000  // small influence
            return s
        }

        return candidates.max { score($0) < score($1) }
    }

    static func subtitleForMatchedWindow(displayName: String, attendeeCount: Int) -> String {
        switch attendeeCount {
        case 0: return displayName
        case 1: return "\(displayName) · 1 attendee"
        default: return "\(displayName) · \(attendeeCount) attendees"
        }
    }

    static func subtitleForDisplayFallback(event: CalendarEvent, displayName: String) -> String {
        guard let url = event.conferenceURL else {
            return "Recording \(displayName)"
        }
        let appName = ConferenceURLAppMap
            .displayName(forBundleID: ConferenceURLAppMap.bundleIDPrefixes(for: url).first ?? "")
            ?? "meeting"
        return "Recording \(displayName) — couldn't find \(appName) window"
    }

    // MARK: - Private

    /// Resolve the display fallback, optionally reusing an already-fetched
    /// `SCShareableContent` to avoid a redundant round-trip to ScreenCaptureKit.
    private func displayFallbackResult(
        event: CalendarEvent,
        fallback: AutoRecordSourceFallback,
        content: SCShareableContent? = nil
    ) async -> AutoRecordResolveResult {
        switch fallback {
        case .skip:
            let url = event.conferenceURL
            let appName = url.flatMap { u in
                ConferenceURLAppMap.displayName(
                    forBundleID: ConferenceURLAppMap.bundleIDPrefixes(for: u).first ?? "")
            } ?? "meeting"
            return .skip(reason: "couldn't find \(appName) window")
        case .display:
            let displays: [SCDisplay]
            if let content {
                displays = content.displays
            } else {
                displays = (try? await SCShareableContent.excludingDesktopWindows(
                    true, onScreenWindowsOnly: true).displays) ?? []
            }
            let display = displays.first { $0.displayID == CGMainDisplayID() } ?? displays.first
            let label = display.map { CaptureSource.displayLabel(displayID: $0.displayID) }
                ?? "primary display"
            let subtitle = Self.subtitleForDisplayFallback(event: event, displayName: label)
            if let display {
                return .source(.display(display), subtitle: subtitle)
            }
            // Worst case: even display enumeration failed → skip.
            return .skip(reason: "no display available")
        }
    }
}
