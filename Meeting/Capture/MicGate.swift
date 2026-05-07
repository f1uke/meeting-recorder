import Foundation
import ApplicationServices

/// Persisted record of when the user's mic was muted in the meeting app
/// during a recording. `TranscriptionSession` reads this to silence
/// Whisper's input over those intervals — prevents the boilerplate
/// hallucinations Whisper emits when the mic captures only echo / ambient
/// noise during muted periods.
///
/// The audio file (`mic.m4a`) is intentionally NOT modified — keeping the
/// raw audio means a misfired detection only costs a re-transcribe (delete
/// `mic_gate.json`, rerun) instead of permanently destroying the user's
/// voice.
struct MicGateFile: Codable, Sendable, Equatable {
    static let filename = "mic_gate.json"
    static let currentVersion = 1

    let version: Int
    /// Half-open intervals in seconds-since-recording-start where the mic
    /// was muted. Sorted by `start`, non-overlapping.
    let muted: [MutedInterval]

    init(muted: [MutedInterval]) {
        self.version = Self.currentVersion
        self.muted = muted
    }

    static func read(from folder: URL) -> MicGateFile? {
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

    /// Total muted duration in seconds — surfaced in the recording window
    /// sublabel ("muted 35% of meeting") and useful for debugging.
    var totalMutedDuration: TimeInterval {
        muted.reduce(0) { $0 + ($1.end - $1.start) }
    }
}

struct MutedInterval: Codable, Sendable, Equatable {
    let start: TimeInterval
    let end: TimeInterval
}

/// Coarse state surfaced to the UI so the user can see at a glance whether
/// the gate is doing anything useful right now. The muted-interval log
/// (the source of truth for transcription gating) is intentionally
/// separate — it advances on `.detected` events but is unaffected by
/// `.lost` (we preserve the last known mic state through the gap).
enum MicGateDetectionState: Sendable, Equatable {
    /// Gate started; detector hasn't returned a successful read yet. Only
    /// a brief moment in practice — usually <200ms before detection lands.
    case awaitingDetection
    /// Detector currently reads the mic button. `isMicActive == true` when
    /// the user is unmuted in Meet, `false` when muted.
    case detected(isMicActive: Bool)
    /// Detector previously had a reading but has stopped seeing the button
    /// (background tab without PiP, page navigation, etc.). The last known
    /// state is preserved — we just lost the ability to track changes.
    case lost
}

/// Owns a `MicStateDetector` for the duration of one recording session and
/// translates state-change events into a list of muted intervals. Created
/// by `RecordingSession.start` when the target window's app is supported
/// (currently Google Chrome only); skipped silently otherwise.
@MainActor
final class MicGate: ObservableObject {
    private let detector: any MicStateDetector
    private var sessionStart: Date?
    private var openMuteStart: TimeInterval?
    private var muted: [MutedInterval] = []
    /// Last `isMicActive` boolean we received from the detector. Used to
    /// restore the right `.detected(...)` state after a `.lost` recovery.
    private var lastKnownActive: Bool?
    /// UI-facing detector state — drives the menu bar mic-gate icon.
    /// Updated on the main actor exclusively so SwiftUI's @Published
    /// re-render path is safe.
    @Published private(set) var detectionState: MicGateDetectionState = .awaitingDetection

    /// Short label of the source the gate is watching ("Meet", "Discord")
    /// — surfaced to the menu bar tooltip so the user can tell which
    /// integration is live without opening the popover.
    var sourceLabel: String { detector.sourceLabel }

    init(detector: any MicStateDetector) {
        self.detector = detector
    }

    /// Starts the underlying detector. `sessionStart` should be the same
    /// `started` Date that lands in `RecordingSession.State.recording` so
    /// the muted intervals share a clock with the transcript timeline.
    func start(sessionStart: Date) {
        self.sessionStart = sessionStart
        self.muted = []
        self.openMuteStart = nil
        self.lastKnownActive = nil
        self.detectionState = .awaitingDetection

        detector.onChange = { [weak self] isActive in
            // Detector fires from a background queue; hop to the main
            // actor before touching our @MainActor state.
            Task { @MainActor in
                self?.handleStateChange(isActive: isActive)
            }
        }
        detector.onSignalLost = { [weak self] in
            Task { @MainActor in
                self?.detectionState = .lost
            }
        }
        detector.onSignalRecovered = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                // Revert UI to the last known concrete state. The
                // detector's `onChange` will overwrite this immediately if
                // the recovered read differs — we just bridge the moment
                // between "recovered" and "first onChange after recovery".
                if let last = self.lastKnownActive {
                    self.detectionState = .detected(isMicActive: last)
                } else {
                    self.detectionState = .awaitingDetection
                }
            }
        }
        detector.start()
    }

    /// Stops the detector and returns the final muted-interval set. Caller
    /// is responsible for writing it to the meeting folder.
    func stop() -> MicGateFile {
        detector.stop()
        // Close any still-open mute interval at the recording's end so we
        // don't lose the last segment if the user stopped while muted.
        if let open = openMuteStart, let start = sessionStart {
            let elapsed = Date().timeIntervalSince(start)
            muted.append(MutedInterval(start: open, end: max(open, elapsed)))
            openMuteStart = nil
        }
        return MicGateFile(muted: muted)
    }

    private func handleStateChange(isActive: Bool) {
        guard let sessionStart else { return }
        let elapsed = Date().timeIntervalSince(sessionStart)
        lastKnownActive = isActive
        detectionState = .detected(isMicActive: isActive)

        if isActive {
            if let open = openMuteStart {
                muted.append(MutedInterval(start: open, end: max(open, elapsed)))
                openMuteStart = nil
                NSLog("[Meeting/MicGate] unmuted at %.2fs (interval %.2f-%.2f)",
                      elapsed, muted.last?.start ?? 0, muted.last?.end ?? 0)
            }
        } else {
            if openMuteStart == nil {
                openMuteStart = elapsed
                NSLog("[Meeting/MicGate] muted at %.2fs", elapsed)
            }
        }
    }
}

// MARK: - Factory

extension MicGate {
    /// Returns a gate appropriate for the recording target, or nil if no
    /// detector is wired for this app. Currently supports:
    ///   - `com.google.Chrome` — assumes the front tab is Google Meet;
    ///     the detector reads UI labels rather than network traffic, so a
    ///     non-Meet tab simply produces an empty interval set.
    ///   - `com.hnc.Discord` — Discord desktop voice panel (Mute/Unmute
    ///     button in the bottom-left user pill).
    ///
    /// Returns nil (and logs) if Accessibility permission isn't granted —
    /// without it AX queries return nothing and the gate would silently
    /// produce no intervals.
    static func create(forBundleID bundleID: String?, pid: pid_t) -> MicGate? {
        guard let bundleID else { return nil }
        guard let detector = makeDetector(forBundleID: bundleID, pid: pid) else {
            return nil
        }
        guard AXIsProcessTrusted() else {
            NSLog("[Meeting/MicGate] skipping gate: Accessibility permission not granted to Meeting.app")
            return nil
        }
        return MicGate(detector: detector)
    }

    private static func makeDetector(forBundleID bundleID: String, pid: pid_t) -> (any MicStateDetector)? {
        switch bundleID {
        // Restricted to Chrome on purpose — Meet UI labels are the same in
        // Brave/Arc/Edge, but each needs its own verification round before
        // we promise it works. Add them after a probe run on the actual app.
        case "com.google.Chrome":
            return AXMicButtonDetector(pid: pid, sourceLabel: "Meet",
                                       parser: GoogleMeetMicParser.parse)
        case "com.hnc.Discord":
            return AXMicButtonDetector(pid: pid, sourceLabel: "Discord",
                                       parser: DiscordMicParser.parse)
        default:
            return nil
        }
    }
}
