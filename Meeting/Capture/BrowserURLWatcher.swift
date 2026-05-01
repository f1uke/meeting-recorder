import Foundation
import AppKit

/// Periodic poll of every running supported browser's front-tab URL.
/// Each navigation captured into the shared `ContextCollector` alongside
/// clipboard items so the LLM summary can see what the user referenced
/// during the meeting.
///
/// Why poll instead of subscribe: macOS doesn't expose a system-wide
/// "user opened this URL" signal. The Accessibility URL field of the
/// browser's address bar is unreliable (focused vs. not, pre-edit text).
/// AppleScript's `URL of active tab` is the documented public API and
/// every Chromium browser + Safari supports it.
///
/// Two-phase lifecycle per browser:
///  1. enumerate — first tick after `start()` lists every currently-
///     open tab's URL via AppleScript and records them as "already
///     seen" without capturing. This is what stops the recording
///     target's tab (e.g. the Google Meet meeting URL) and any other
///     pre-existing reference tabs from polluting the captured list:
///     the user only wanted *new* navigation captured, not whatever
///     was open at recording start.
///  2. poll — every subsequent tick reads only the front tab. URLs
///     not in the seen set are captured as new, and added to the set
///     so they don't repeat. Switching back to a pre-existing tab
///     (already in the snapshot) is silently skipped — exactly the
///     "don't capture tabs I just looked at" behavior the user asked
///     for.
///
/// Runs both AppleScripts via the `osascript` subprocess on a detached
/// task — NSAppleScript.executeAndReturnError pumps Apple events through
/// the calling thread's runloop, which means a hung target browser (or
/// a hidden TCC approval dialog) freezes the entire main thread.
/// Blocked-main was breaking AVAudioEngine's state machine and locking
/// out the Stop button, so this watcher must stay off-main.
///
/// First poll against each browser triggers a TCC dialog ("Meeting wants
/// to control Safari…") because of the automation entitlement; the user
/// approves once per browser, then it's silent. Failures (denied, browser
/// closed, AppleScript error) are logged and the watcher carries on with
/// other browsers — one reluctant target shouldn't take down the rest.
@MainActor
final class BrowserURLWatcher {
    private let collector: ContextCollector
    private var timer: Timer?
    /// URLs we've already captured (or snapshotted as pre-existing) per
    /// bundle ID. Anything in here is silently skipped on subsequent
    /// polls so the same tab doesn't get logged repeatedly and tabs
    /// open at recording start don't pollute the captured list.
    private var seenURLs: [String: Set<String>] = [:]
    /// Bundle IDs whose initial enumeration has completed (success or
    /// failure). Until set, the watcher won't poll the front tab — it
    /// runs the full enumeration first so the recording target URL
    /// (and any other pre-open tabs) get pre-populated as "seen".
    private var enumerated: Set<String> = []
    /// Bundle IDs whose poll subprocess hasn't returned yet. Skipped on
    /// subsequent ticks so we don't spawn N parallel `osascript` calls
    /// for the same target.
    private var inFlight: Set<String> = []

    init(collector: ContextCollector) {
        self.collector = collector
    }

    /// Browsers we know how to script. Each entry pairs the bundle ID
    /// (used to check if it's running) with two AppleScript fragments:
    /// one that lists every open tab's URL (one per line) for the
    /// snapshot pass, and one that returns the front tab's
    /// `URL\ntitle` for ongoing polls.
    private struct Target: Sendable {
        let bundleID: String
        let displayName: String
        let enumerateScript: String
        let frontTabScript: String
    }

    private static let targets: [Target] = [
        Target(
            bundleID: "com.apple.Safari",
            displayName: "Safari",
            enumerateScript: safariEnumerateScript,
            frontTabScript: """
            tell application "Safari"
                if (count of windows) is 0 then return ""
                set theTab to current tab of front window
                return (URL of theTab) & linefeed & (name of theTab)
            end tell
            """
        ),
        // Chromium family — same dictionary for Chrome, Edge, Brave, Arc,
        // Vivaldi, etc. We send the same script template per bundle so the
        // dialog text reads "Meeting wants to control <browser>" instead
        // of always saying Chrome.
        Target(
            bundleID: "com.google.Chrome",
            displayName: "Google Chrome",
            enumerateScript: chromeEnumerateScript(for: "Google Chrome"),
            frontTabScript: chromeFrontTabScript(for: "Google Chrome")
        ),
        Target(
            bundleID: "com.microsoft.edgemac",
            displayName: "Microsoft Edge",
            enumerateScript: chromeEnumerateScript(for: "Microsoft Edge"),
            frontTabScript: chromeFrontTabScript(for: "Microsoft Edge")
        ),
        Target(
            bundleID: "com.brave.Browser",
            displayName: "Brave Browser",
            enumerateScript: chromeEnumerateScript(for: "Brave Browser"),
            frontTabScript: chromeFrontTabScript(for: "Brave Browser")
        ),
        Target(
            bundleID: "company.thebrowser.Browser",
            displayName: "Arc",
            enumerateScript: chromeEnumerateScript(for: "Arc"),
            frontTabScript: chromeFrontTabScript(for: "Arc")
        ),
    ]

    private static let safariEnumerateScript = """
    tell application "Safari"
        set output to ""
        repeat with w in windows
            repeat with t in tabs of w
                set output to output & (URL of t) & linefeed
            end repeat
        end repeat
        return output
    end tell
    """

    private static func chromeEnumerateScript(for app: String) -> String {
        """
        tell application "\(app)"
            set output to ""
            repeat with w in windows
                repeat with t in tabs of w
                    set output to output & (URL of t) & linefeed
                end repeat
            end repeat
            return output
        end tell
        """
    }

    private static func chromeFrontTabScript(for app: String) -> String {
        """
        tell application "\(app)"
            if (count of windows) is 0 then return ""
            set theTab to active tab of front window
            return (URL of theTab) & linefeed & (title of theTab)
        end tell
        """
    }

    /// First tick is intentionally deferred to `interval` seconds after
    /// start (rather than firing immediately). The audio pipeline needs
    /// a moment to stabilize after `RecordingSession.start` brings up
    /// AVAudioEngine + the per-process Core Audio Tap; spawning Apple
    /// event subprocesses on top of that during the same runloop
    /// slice has shown to confuse voice-processing audio units in the
    /// meeting app and produce dropped audio.
    func start(interval: TimeInterval = 5.0) {
        let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Internals

    private func tick() {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
        for target in Self.targets
        where running.contains(target.bundleID) && !inFlight.contains(target.bundleID) {
            inFlight.insert(target.bundleID)
            if enumerated.contains(target.bundleID) {
                Task { [weak self] in
                    let result = await Self.runFrontTabOffMain(target: target)
                    self?.handlePoll(result: result, target: target)
                }
            } else {
                Task { [weak self] in
                    let urls = await Self.runEnumerateOffMain(target: target)
                    self?.handleEnumerate(urls: urls, target: target)
                }
            }
        }
    }

    /// Snapshot every URL the browser currently has open. Treated as
    /// "already seen" so they won't be captured by subsequent polls.
    /// On AppleScript failure (TCC denied, browser hung) we still mark
    /// the bundle as enumerated so the next tick falls through to
    /// polling — losing the snapshot only means the front tab gets
    /// captured once, not repeatedly.
    private func handleEnumerate(urls: [String]?, target: Target) {
        inFlight.remove(target.bundleID)
        enumerated.insert(target.bundleID)
        let valid = (urls ?? []).filter { $0.hasPrefix("http://") || $0.hasPrefix("https://") }
        seenURLs[target.bundleID] = Set(valid)
        NSLog("[Meeting/Browser] enumerated %@: %d pre-existing URLs",
              target.displayName, valid.count)
    }

    /// Apply a poll result on the main actor: remove the in-flight
    /// flag, skip if the URL was already seen (snapshot or earlier
    /// capture), otherwise add it to seen and push to the collector.
    private func handlePoll(result: ScriptResult?, target: Target) {
        inFlight.remove(target.bundleID)
        guard let result, !result.url.isEmpty else { return }
        // Drop chrome://, about:, file://, etc. — only http/https
        // are useful in a meeting summary.
        guard result.url.hasPrefix("http://") || result.url.hasPrefix("https://") else { return }

        var seen = seenURLs[target.bundleID] ?? []
        guard !seen.contains(result.url) else { return }
        seen.insert(result.url)
        seenURLs[target.bundleID] = seen

        let url = result.url
        let title = result.title
        let displayName = target.displayName
        Task { [collector] in
            await collector.append(
                kind: .url,
                source: .browser,
                text: url,
                browserName: displayName,
                pageTitle: title
            )
        }
        NSLog("[Meeting/Browser] %@: %@", target.displayName, url)
    }

    private struct ScriptResult: Sendable {
        let url: String
        let title: String?
    }

    /// Detaches the synchronous front-tab `osascript` subprocess off
    /// the main actor so a hung browser can't lock the UI. The static
    /// helper captures only `target` (Sendable) — no `self` — so
    /// strict concurrency stays happy.
    nonisolated private static func runFrontTabOffMain(target: Target) async -> ScriptResult? {
        await Task.detached(priority: .background) {
            runFrontTab(target: target)
        }.value
    }

    /// Detaches the synchronous enumeration subprocess off the main
    /// actor. Same Sendable rules as the front-tab version.
    nonisolated private static func runEnumerateOffMain(target: Target) async -> [String]? {
        await Task.detached(priority: .background) {
            runEnumerate(target: target)
        }.value
    }

    nonisolated static let scriptTimeoutSeconds: Double = 5

    nonisolated private static func runFrontTab(target: Target) -> ScriptResult? {
        guard let raw = runScript(target: target, source: target.frontTabScript) else { return nil }
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let url = lines.first, !url.isEmpty else { return nil }
        let title = lines.count > 1 && !lines[1].isEmpty ? lines[1] : nil
        return ScriptResult(url: url, title: title)
    }

    nonisolated private static func runEnumerate(target: Target) -> [String]? {
        guard let raw = runScript(target: target, source: target.enumerateScript) else { return nil }
        return raw.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Spawn `osascript -e <script>` with a wall-clock timeout. The
    /// timeout exists so a hung browser can't leak subprocesses; we'd
    /// rather miss one URL than accumulate zombie processes for the
    /// duration of the meeting. Enumeration gets the same budget as
    /// front-tab polls — listing every tab is still O(tabs) AppleScript
    /// dispatches inside the target, which finishes well under 5 s
    /// even on power users with hundreds of tabs.
    nonisolated private static func runScript(target: Target, source: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", source]
        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr
        do {
            try proc.run()
        } catch {
            NSLog("[Meeting/Browser] osascript launch failed for %@: %@",
                  target.displayName, String(describing: error))
            return nil
        }

        let killer = DispatchWorkItem {
            if proc.isRunning { proc.terminate() }
        }
        DispatchQueue.global(qos: .background)
            .asyncAfter(deadline: .now() + scriptTimeoutSeconds, execute: killer)
        proc.waitUntilExit()
        killer.cancel()

        guard proc.terminationStatus == 0 else {
            // Status 1 with a -1743 in stderr is the "user denied
            // automation" case — log once via stderr and forget.
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            let errStr = String(data: errData, encoding: .utf8) ?? ""
            if !errStr.contains("-1743") {
                NSLog("[Meeting/Browser] osascript exit %d for %@: %@",
                      proc.terminationStatus, target.displayName, errStr.prefix(200) as CVarArg)
            }
            return nil
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }
}
