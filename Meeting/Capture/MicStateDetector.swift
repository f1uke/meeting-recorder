import Foundation
import AppKit
import ApplicationServices

/// Reports whether the user's mic is currently *active in the meeting app*
/// — NOT whether the OS-level mic stream is open. Google Meet, Zoom,
/// Discord, and most WebRTC / VoIP clients keep the audio device open
/// continuously and toggle a software mute internally; the OS sees the mic
/// as in-use either way, so we have to read meeting-app UI state instead.
///
/// The detector polls some app-specific signal on a background queue and
/// fires `onChange` whenever the observed state flips (with hysteresis so
/// brief detection blips don't pollute the muted-interval log).
///
/// `nil` from `lastObserved` means the detector hasn't been able to read
/// state yet (button not found, accessibility denied, page not on the
/// meeting yet) — callers should treat that as "assume mic is active",
/// since incorrectly silencing real speech is worse than transcribing a
/// few seconds of muted audio.
protocol MicStateDetector: AnyObject, Sendable {
    /// Short user-facing name of the source the detector watches —
    /// "Meet", "Discord", … — used in menu bar tooltips and logs so the
    /// user can tell which integration is live.
    var sourceLabel: String { get }
    /// Called from a background queue when the committed state changes.
    /// Implementations guarantee the bool reflects the current state at the
    /// moment of the call (after hysteresis).
    var onChange: (@Sendable (Bool) -> Void)? { get set }
    /// Called when the detector has gone N consecutive polls without being
    /// able to read state (button not findable). Used by MicGate to update
    /// the UI indicator — does NOT alter the muted-interval log, since the
    /// last known state is preserved across signal losses.
    var onSignalLost: (@Sendable () -> Void)? { get set }
    /// Called when the detector recovers from a lost-signal state.
    var onSignalRecovered: (@Sendable () -> Void)? { get set }
    func start()
    func stop()
}

// MARK: - Generic AX-button mic detector

/// Walks a target app's accessibility tree looking for an `AXButton` whose
/// label/description matches a bundle-specific parser, and polls it for
/// the user's current mute state. Used for both Google Meet (in Chrome)
/// and Discord — the polling, hysteresis, signal-loss, and tree-walk
/// machinery is identical; only the button identification differs.
///
/// NOT @MainActor: the polling timer fires on a background dispatch queue
/// to keep main responsive, and AX queries can take 10-100ms when the
/// cached reference goes stale.
final class AXMicButtonDetector: MicStateDetector, @unchecked Sendable {
    /// Maps an AX element's title + description to a mic-active boolean.
    /// Returns `nil` for elements that don't match the target button —
    /// the walker uses that as the rejection signal and keeps searching.
    typealias Parser = @Sendable (_ title: String?, _ description: String?) -> Bool?

    let sourceLabel: String
    var onChange: (@Sendable (Bool) -> Void)?
    var onSignalLost: (@Sendable () -> Void)?
    var onSignalRecovered: (@Sendable () -> Void)?

    private let pid: pid_t
    private let parser: Parser
    private let queue = DispatchQueue(label: "dev.fluke.meeting.mic-detector",
                                      qos: .userInitiated)
    private let pollInterval: DispatchTimeInterval = .milliseconds(200)
    /// A new state must be observed continuously for this long before being
    /// committed via `onChange`. Guards against single-frame AX glitches
    /// when the page is mid-render.
    private let hysteresis: TimeInterval = 0.30
    /// Number of consecutive nil reads before we report the signal as lost.
    /// 5 polls × 200ms = 1s — long enough to ride through transient AX
    /// hiccups during page re-render, short enough to flag a real lost
    /// signal (background tab outside PiP) within a beat.
    private let lostThresholdPolls = 5
    private let maxWalkDepth = 60

    // Background-queue-only state. `@unchecked Sendable` is honest because
    // every read/write below happens inside `queue`.
    private var timer: DispatchSourceTimer?
    private var cachedButton: AXUIElement?
    private var lastReported: Bool?
    private var pendingState: Bool?
    private var pendingSince: Date?
    private var loggedNoButton = false
    private var consecutiveNilReads = 0
    private var inLostState = false

    init(pid: pid_t, sourceLabel: String, parser: @escaping Parser) {
        self.pid = pid
        self.sourceLabel = sourceLabel
        self.parser = parser
    }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            // First poll runs synchronously so we have a baseline state to
            // report immediately (no 200ms wait for the first tick). The
            // initial state bypasses hysteresis — there's no prior state
            // for it to be unstable against.
            if let initial = self.readMicStateLocked() {
                self.lastReported = initial
                self.onChange?(initial)
            }

            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + .milliseconds(200),
                           repeating: self.pollInterval)
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.timer = timer
        }
    }

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            cachedButton = nil
            pendingState = nil
            pendingSince = nil
            consecutiveNilReads = 0
            inLostState = false
        }
    }

    // MARK: - Polling

    private func tick() {
        guard let observed = readMicStateLocked() else {
            // No signal — invalidate cache for next attempt but keep the
            // last reported state stable. Don't fire onChange; consumers
            // already assume "active" when they have no data.
            cachedButton = nil
            consecutiveNilReads += 1
            if consecutiveNilReads >= lostThresholdPolls && !inLostState {
                inLostState = true
                NSLog("[Meeting/MicGate] %@ signal lost (after %d consecutive nil reads)",
                      sourceLabel, consecutiveNilReads)
                onSignalLost?()
            }
            return
        }

        // We have a successful read. If we were in a lost-signal state,
        // surface the recovery before we fall through to the change check.
        if inLostState {
            inLostState = false
            NSLog("[Meeting/MicGate] %@ signal recovered", sourceLabel)
            onSignalRecovered?()
        }
        consecutiveNilReads = 0

        // Hysteresis: only commit a change after `observed` has been the
        // candidate for at least `hysteresis` seconds.
        if observed == lastReported {
            pendingState = nil
            pendingSince = nil
            return
        }
        let now = Date()
        if pendingState != observed {
            pendingState = observed
            pendingSince = now
            return
        }
        if let since = pendingSince, now.timeIntervalSince(since) >= hysteresis {
            lastReported = observed
            pendingState = nil
            pendingSince = nil
            onChange?(observed)
        }
    }

    /// Returns `true` if mic is unmuted, `false` if muted, `nil` if the
    /// button can't be located right now.
    private func readMicStateLocked() -> Bool? {
        if let cached = cachedButton, let state = readButtonState(cached) {
            return state
        }
        cachedButton = nil

        let app = AXUIElementCreateApplication(pid)
        guard let button = walkForMicButton(app, depth: 0) else {
            if !loggedNoButton {
                loggedNoButton = true
                NSLog("[Meeting/MicGate] %@ mic button not found in pid=%d — gate stays open until the meeting UI exposes it",
                      sourceLabel, pid)
            }
            return nil
        }
        if loggedNoButton {
            loggedNoButton = false
            NSLog("[Meeting/MicGate] %@ mic button located", sourceLabel)
        }
        cachedButton = button
        return readButtonState(button)
    }

    private func readButtonState(_ element: AXUIElement) -> Bool? {
        let title = readString(element, kAXTitleAttribute as CFString)
        let desc = readString(element, kAXDescriptionAttribute as CFString)
        if title == nil && desc == nil { return nil }
        return parser(title, desc)
    }

    private func walkForMicButton(_ element: AXUIElement, depth: Int) -> AXUIElement? {
        guard depth < maxWalkDepth else { return nil }

        // Only AXButton can be the mic toggle; cheap pre-filter via role.
        if let role = readString(element, kAXRoleAttribute as CFString),
           role == kAXButtonRole as String,
           readButtonState(element) != nil {
            return element
        }

        var childrenValue: AnyObject?
        guard AXUIElementCopyAttributeValue(
            element, kAXChildrenAttribute as CFString, &childrenValue
        ) == .success,
              let children = childrenValue as? [AXUIElement] else {
            return nil
        }
        for child in children {
            if let found = walkForMicButton(child, depth: depth + 1) {
                return found
            }
        }
        return nil
    }

    // MARK: - AX helpers

    private func readString(_ element: AXUIElement, _ name: CFString) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success else {
            return nil
        }
        return value as? String
    }
}

// MARK: - Per-app parsers

/// Google Meet's mic toggle (in Chrome's web view) carries the action in
/// its AXDescription. Verified against Google Meet on 2026-04-30:
///   - muted   → AXDescription = "Turn on microphone"
///   - unmuted → AXDescription = "Turn off microphone"
enum GoogleMeetMicParser {
    static let parse: AXMicButtonDetector.Parser = { _, description in
        guard let description else { return nil }
        let lc = description.lowercased()
        // Button label describes the action it offers, not the current state.
        if lc.contains("turn off microphone") { return true }   // mic ON
        if lc.contains("turn on microphone") { return false }   // mic MUTED
        return nil
    }
}

/// Discord's voice-panel mic toggle exposes its action via AXTitle (and
/// occasionally AXDescription as a fallback). Discord ships separate
/// "Mute" and "Deafen" buttons in the same panel, so we explicitly reject
/// anything that mentions deafen to avoid latching onto the wrong one.
///   - muted   → label starts with "Unmute"
///   - unmuted → label starts with "Mute"
enum DiscordMicParser {
    static let parse: AXMicButtonDetector.Parser = { title, description in
        for candidate in [title, description] {
            guard let raw = candidate else { continue }
            let lc = raw.lowercased()
            // "Deafen" / "Undeafen" buttons live next to the mic toggle.
            // Bail before we mistake them for the mic.
            if lc.contains("deafen") { continue }
            // Match on word boundaries — "unmute" must be a standalone
            // word/prefix so phrases like "menu mute…" don't false-fire.
            if lc.hasPrefix("unmute") || lc == "unmute" { return false }
            if lc.hasPrefix("mute") || lc == "mute" { return true }
        }
        return nil
    }
}
