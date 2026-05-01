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
/// Runs the AppleScript via the `osascript` subprocess on a detached
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
    /// Last URL captured per bundle ID. Used to dedupe consecutive polls
    /// of the same tab — only navigation events get added.
    private var lastURL: [String: String] = [:]
    /// Bundle IDs whose poll subprocess hasn't returned yet. Skipped on
    /// subsequent ticks so we don't spawn N parallel `osascript` calls
    /// for the same target.
    private var inFlight: Set<String> = []

    init(collector: ContextCollector) {
        self.collector = collector
    }

    /// Browsers we know how to script. Each entry pairs the bundle ID
    /// (used to check if it's running) with the AppleScript fragment
    /// that returns "<URL>\n<title>". Order doesn't matter.
    private struct Target: Sendable {
        let bundleID: String
        let displayName: String
        let script: String
    }

    private static let targets: [Target] = [
        Target(
            bundleID: "com.apple.Safari",
            displayName: "Safari",
            script: """
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
            script: chromeScript(for: "Google Chrome")
        ),
        Target(
            bundleID: "com.microsoft.edgemac",
            displayName: "Microsoft Edge",
            script: chromeScript(for: "Microsoft Edge")
        ),
        Target(
            bundleID: "com.brave.Browser",
            displayName: "Brave Browser",
            script: chromeScript(for: "Brave Browser")
        ),
        Target(
            bundleID: "company.thebrowser.Browser",
            displayName: "Arc",
            script: chromeScript(for: "Arc")
        ),
    ]

    private static func chromeScript(for app: String) -> String {
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
            // The Task inherits MainActor isolation; the heavy lifting
            // (Process subprocess) is hopped off via `Task.detached`
            // inside `runOsascriptOffMain`. We stay on main only to
            // mutate `inFlight` / `lastURL` and to await the result.
            Task { [weak self] in
                let result = await Self.runOsascriptOffMain(target: target)
                self?.handle(result: result, target: target)
            }
        }
    }

    /// Apply a poll result on the main actor: remove the in-flight
    /// flag, dedupe against the last URL, and forward to the collector.
    private func handle(result: ScriptResult?, target: Target) {
        inFlight.remove(target.bundleID)
        guard let result, !result.url.isEmpty else { return }
        // Drop chrome://, about:, file://, etc. — only http/https
        // are useful in a meeting summary.
        guard result.url.hasPrefix("http://") || result.url.hasPrefix("https://") else { return }
        guard lastURL[target.bundleID] != result.url else { return }
        lastURL[target.bundleID] = result.url

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

    /// Detaches the synchronous `osascript` subprocess off the main
    /// actor so a hung browser can't lock the UI. The static helper
    /// captures only `target` (Sendable) — no `self` — so strict
    /// concurrency stays happy.
    nonisolated private static func runOsascriptOffMain(target: Target) async -> ScriptResult? {
        await Task.detached(priority: .background) {
            runOsascript(target: target)
        }.value
    }

    /// Spawn `osascript -e <script>` with a 3 s wall-clock timeout. The
    /// timeout exists so a hung browser can't leak subprocesses; we'd
    /// rather miss one URL than accumulate zombie processes for the
    /// duration of the meeting.
    nonisolated private static func runOsascript(target: Target) -> ScriptResult? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", target.script]
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

        // Best-effort timeout. DispatchWorkItem runs after 3 s and SIGTERMs
        // the subprocess if it's still alive. Since waitUntilExit returns
        // as soon as the process dies (terminated or otherwise), this
        // doesn't add latency to fast-responding browsers.
        let killer = DispatchWorkItem {
            if proc.isRunning { proc.terminate() }
        }
        DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 3, execute: killer)
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
        let raw = String(data: data, encoding: .utf8) ?? ""
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let url = lines.first, !url.isEmpty else { return nil }
        let title = lines.count > 1 && !lines[1].isEmpty ? lines[1] : nil
        return ScriptResult(url: url, title: title)
    }
}
