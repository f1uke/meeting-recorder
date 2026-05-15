import Foundation
import ScreenCaptureKit
import AVFoundation
import Combine
import AppKit

@MainActor
final class RecordingSession: ObservableObject {
    enum State: Equatable {
        case idle
        case starting
        case recording(folder: URL, started: Date)
        case stopping
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastFolder: URL?
    @Published private(set) var errorMessage: String?
    /// Window title of the source being recorded (for headers like
    /// "Q2 Roadmap Sync — Zoom"). Cleared when not recording.
    @Published private(set) var currentSourceTitle: String?
    /// Owning application name — paired with `currentSourceTitle`.
    @Published private(set) var currentSourceApp: String?
    /// Calendar event the user attached to this recording (if any). Drives
    /// the recording header's "Q2 Roadmap Sync · 4 attendees" line and is
    /// persisted to `<folder>/calendar.json` on stop so the Library can
    /// surface attendees + organizer + conference URL.
    @Published private(set) var currentEvent: CalendarEvent?
    /// Mic device label for the recording window's "You · mic" sub-label.
    @Published private(set) var micDeviceName: String?
    /// Number of audio process objects bridged by the output tap. Surfaced
    /// to confirm Electron multi-helper detection is wired up.
    @Published private(set) var tapProcessCount: Int = 0
    /// Mic-gate detection state — drives the menu bar mic-gate icon.
    /// `nil` when no gate is active for this recording (unsupported target,
    /// Accessibility not granted, or before/after recording). Otherwise
    /// mirrors `MicGate.detectionState` published from the gate.
    @Published private(set) var micGateState: MicGateDetectionState?
    /// Short label of the meeting source the active gate is watching
    /// ("Meet" or "Discord") — used by the menu bar tooltip so the user
    /// can tell which integration is reading their mute state. `nil`
    /// whenever `micGateState` is `nil`.
    @Published private(set) var micGateSource: String?

    /// Live mic-level ring buffer — the popover and recording window read
    /// from this each frame to draw the user's waveform. Survives recorder
    /// restart by being owned at the session level.
    let micRMS = RMSRingBuffer(capacity: 96)
    /// Live meeting-output level ring buffer.
    let outputRMS = RMSRingBuffer(capacity: 96)

    private var coordinator: ScreenCaptureCoordinator?
    private var micRecorder: MicRecorder?
    private var processAudioTap: ProcessAudioTap?
    private var micGate: MicGate?
    private var micGateCancellable: AnyCancellable?
    private var meetParticipants: MeetParticipantsCollector?
    private var clipboardWatcher: ClipboardWatcher?
    private var browserWatcher: BrowserURLWatcher?
    private var contextCollector: ContextCollector?
    private var currentFolder: URL?

    var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    func start(source: CaptureSource, event: CalendarEvent? = nil) async {
        guard state == .idle else {
            NSLog("[Meeting/Session] start: bail — state is %@, expected .idle",
                  String(describing: state))
            return
        }
        state = .starting
        errorMessage = nil
        currentEvent = event
        micRMS.reset()
        outputRMS.reset()

        // Watchdog: if any step hangs for 45s, force back to .idle with
        // an actionable errorMessage. The await in `coord.start` /
        // `engine.start()` / `AudioDeviceStart` can stall on TCC
        // re-prompts that the user can't see.
        scheduleStartWatchdog()

        let folder: URL
        do {
            folder = try Self.createFolder(in: AppPreferences.shared.meetingsFolderURL)
            NSLog("[Meeting/Session] start: created folder %@",
                  folder.path(percentEncoded: false))
        } catch {
            failStart("ไม่สามารถสร้างโฟลเดอร์: \(error.localizedDescription)")
            return
        }
        currentFolder = folder

        let videoURL = folder.appendingPathComponent("video.mov")
        let micURL = folder.appendingPathComponent("mic.m4a")
        let outputURL = folder.appendingPathComponent("output.m4a")

        // Per-source identity. Window mode has rich integrations
        // (mic gate, Meet scraper) that depend on bundle ID / PID;
        // display mode skips them.
        let sourcePID: pid_t? = source.pid
        let sourceBundleID: String? = source.bundleID
        NSLog("[Meeting/Session] start: source=%@ pid=%@ bundle=%@",
              String(describing: source),
              sourcePID.map(String.init) ?? "(none)",
              sourceBundleID ?? "(none)")

        // Step 1: screen capture.
        NSLog("[Meeting/Session] start: step 1 — SCStream.startCapture …")
        let coord = ScreenCaptureCoordinator()
        do {
            try await coord.start(source: source, videoURL: videoURL)
            guard state == .starting else {
                try? await coord.stop()
                NSLog("[Meeting/Session] start: cancelled during step 1 — rolled back")
                return
            }
            self.coordinator = coord
            NSLog("[Meeting/Session] start: step 1 done — SCStream live")
        } catch {
            NSLog("[Meeting/Session] start: step 1 FAILED: %@", String(describing: error))
            failStart("ScreenCapture เริ่มไม่ได้: \(error.localizedDescription)")
            return
        }

        // Step 2: mic. `AVAudioEngine.start()` is synchronous and can
        // block for hundreds of ms (longer on TCC/audio-unit init), so
        // it runs off the main actor to keep the UI responsive.
        NSLog("[Meeting/Session] start: step 2 — AVAudioEngine input tap …")
        let mic = MicRecorder()
        do {
            let micURLLocal = micURL
            let micRMSLocal = micRMS
            // Snapshot the user's pinned device on the main actor before
            // hopping off — keeps actor isolation clean and means the
            // value used during start matches whatever Settings showed.
            let pinnedUID = AppPreferences.shared.micDeviceUID
            try await Task.detached(priority: .userInitiated) {
                try mic.start(url: micURLLocal, deviceUID: pinnedUID, rmsBuffer: micRMSLocal)
            }.value
            guard state == .starting else {
                mic.stop()
                NSLog("[Meeting/Session] start: cancelled during step 2 — rolled back")
                return
            }
            self.micRecorder = mic
            self.micDeviceName = mic.deviceName
            NSLog("[Meeting/Session] start: step 2 done — mic device=%@",
                  mic.deviceName ?? "(unknown)")
        } catch {
            NSLog("[Meeting/Session] start: step 2 FAILED: %@", String(describing: error))
            try? await coord.stop()
            self.coordinator = nil
            failStart("Microphone เริ่มไม่ได้: \(error.localizedDescription)")
            return
        }

        // Step 3: audio tap. Per-process for window sources; system-wide
        // for display sources. CoreAudio HAL setup
        // (AudioHardwareCreateProcessTap / CreateAggregateDevice /
        // AudioDeviceStart) is sync and the slowest leg — off-main for
        // the same reason as step 2.
        NSLog("[Meeting/Session] start: step 3 — Core Audio Tap …")
        let tap = ProcessAudioTap()
        do {
            let outputURLLocal = outputURL
            let outputRMSLocal = outputRMS
            let tapTarget: ProcessAudioTap.TapTarget
            if let pid = sourcePID, let bundle = sourceBundleID {
                tapTarget = .process(pid: pid, bundleID: bundle)
            } else {
                tapTarget = .system
            }
            try await Task.detached(priority: .userInitiated) {
                try tap.start(
                    target: tapTarget,
                    url: outputURLLocal,
                    rmsBuffer: outputRMSLocal
                )
            }.value
            guard state == .starting else {
                tap.stop()
                NSLog("[Meeting/Session] start: cancelled during step 3 — rolled back")
                return
            }
            self.processAudioTap = tap
            self.tapProcessCount = tap.processCount
            NSLog("[Meeting/Session] start: step 3 done — tap processCount=%d",
                  tap.processCount)
        } catch {
            NSLog("[Meeting/Session] start: step 3 FAILED: %@", String(describing: error))
            mic.stop()
            self.micRecorder = nil
            try? await coord.stop()
            self.coordinator = nil
            failStart("Process audio tap เริ่มไม่ได้: \(error.localizedDescription)")
            return
        }

        currentSourceTitle = source.title
        currentSourceApp = source.app
        let recordingStart = Date()
        state = .recording(folder: folder, started: recordingStart)

        // Step 4: mic gate (optional). Watches the meeting app's UI to know
        // when the user has muted themselves in Meet, so the transcription
        // pipeline can later silence Whisper's input over those intervals.
        // Skipped for display sources (no bundleID to bind a gate to).
        // Failure here is non-fatal — recording proceeds without gating.
        if let bundle = sourceBundleID, let pid = sourcePID,
           let gate = MicGate.create(forBundleID: bundle, pid: pid) {
            gate.start(sessionStart: recordingStart)
            self.micGate = gate
            // Mirror the gate's detection state into our own @Published so
            // MenuBarLabel (which observes RecordingSession) can react —
            // an inner ObservableObject would not republish through a
            // parent's @Published of a class.
            self.micGateState = gate.detectionState
            self.micGateSource = gate.sourceLabel
            self.micGateCancellable = gate.$detectionState.sink { [weak self] state in
                self?.micGateState = state
            }
            NSLog("[Meeting/Session] start: step 4 done — MicGate active for bundle=%@ source=%@",
                  bundle, gate.sourceLabel)
        } else {
            NSLog("[Meeting/Session] start: step 4 skipped — no bundleID or no MicGate for source")
        }

        // Step 5: Meet participants AX scrape (Chrome only). Periodic
        // capture of video tile names so the Library detail can show who
        // actually joined — fills the gap when the calendar invitee list
        // contains only a group email (which EventKit can't expand).
        // Skipped for display sources (no PID to attach AX to).
        if sourceBundleID == "com.google.Chrome",
           let pid = sourcePID, AXIsProcessTrusted() {
            let collector = MeetParticipantsCollector(pid: pid)
            collector.start()
            self.meetParticipants = collector
            NSLog("[Meeting/Session] start: step 5 done — MeetParticipantsCollector active")
        }

        // Step 6: clipboard + browser-URL watchers. Both push into a
        // shared ContextCollector so the meeting picks up text/links/
        // images the user copies and pages they navigate to during the
        // call — folded into the LLM summary later. Failure here is
        // non-fatal; recording proceeds without context capture.
        let collector = ContextCollector(recordingStart: recordingStart)
        self.contextCollector = collector
        let cw = ClipboardWatcher(collector: collector, meetingFolder: folder)
        cw.start()
        self.clipboardWatcher = cw
        let bw = BrowserURLWatcher(collector: collector)
        bw.start()
        self.browserWatcher = bw
        NSLog("[Meeting/Session] start: step 6 done — context watchers active")

        cancelStartWatchdog()
        NSLog("[Meeting/Session] start: ALL READY — state=recording")
    }

    /// User-facing escape hatch from the .starting state. Called by the
    /// "Cancel start" button in PopoverTransientView when the spinner
    /// has been showing for an unreasonably long time.
    func cancelStart() {
        NSLog("[Meeting/Session] cancelStart from state=%@",
              String(describing: state))
        _ = micGate?.stop()
        micGate = nil
        micGateCancellable = nil
        micGateState = nil
        micGateSource = nil
        meetParticipants?.stop()
        meetParticipants = nil
        clipboardWatcher?.stop()
        clipboardWatcher = nil
        browserWatcher?.stop()
        browserWatcher = nil
        contextCollector = nil
        micRecorder?.stop()
        micRecorder = nil
        processAudioTap?.stop()
        processAudioTap = nil
        if let coord = coordinator {
            Task { try? await coord.stop() }
        }
        coordinator = nil
        currentFolder = nil
        currentSourceTitle = nil
        currentSourceApp = nil
        currentEvent = nil
        micDeviceName = nil
        tapProcessCount = 0
        cancelStartWatchdog()
        if errorMessage == nil {
            errorMessage = "Recording start cancelled."
        }
        state = .idle
    }

    // MARK: - Internals

    private var startWatchdog: Task<Void, Never>?

    private func scheduleStartWatchdog() {
        startWatchdog?.cancel()
        startWatchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 45 * 1_000_000_000)
            guard !Task.isCancelled, let self else { return }
            if self.state == .starting {
                NSLog("[Meeting/Session] WATCHDOG: still .starting after 45s — aborting")
                self.errorMessage = "Recording start hung for 45 s. Check Console.app for `[Meeting/Session]` logs to see which step stalled (likely a hidden TCC dialog or an unsigned binary)."
                self.cancelStart()
            }
        }
    }

    private func cancelStartWatchdog() {
        startWatchdog?.cancel()
        startWatchdog = nil
    }

    /// Reset state to .idle with the given error and clean up any
    /// resources that were already started before the failing step.
    private func failStart(_ message: String) {
        errorMessage = message
        currentFolder = nil
        cancelStartWatchdog()
        state = .idle
    }

    func stop() async {
        guard case .recording = state else { return }
        state = .stopping

        // Stop the mic gate first so any still-open mute interval gets
        // closed against the same wall clock as the audio finalize.
        let gateFile = micGate?.stop()
        micGate = nil
        micGateCancellable = nil
        micGateState = nil
        micGateSource = nil

        // Stop Meet participants collector and capture its accumulated set.
        // Final scrape happens below — by stopping the timer first we
        // prevent a race where another scrape starts while we read the set.
        meetParticipants?.stop()
        let participantNames = meetParticipants?.allParticipants ?? []
        meetParticipants = nil

        // Stop context watchers (clipboard / browser-URL polls) and
        // capture the final set of items. Reading the collector requires
        // an actor hop — we do it before tearing down the audio pipeline
        // so the items can be persisted alongside the meeting's other
        // sidecar JSONs below.
        clipboardWatcher?.stop()
        clipboardWatcher = nil
        browserWatcher?.stop()
        browserWatcher = nil
        let capturedContext: [ContextItem]
        if let collector = contextCollector {
            capturedContext = await collector.snapshot()
        } else {
            capturedContext = []
        }
        contextCollector = nil

        // Stop audio sources next so each m4a's moov atom is finalized
        // before we tear down the recording session.
        micRecorder?.stop()
        micRecorder = nil

        processAudioTap?.stop()
        processAudioTap = nil

        do {
            try await coordinator?.stop()
        } catch {
            errorMessage = "หยุด ScreenCapture ผิดพลาด: \(error.localizedDescription)"
        }
        coordinator = nil

        if let folder = currentFolder {
            // mic_gate.json — only written when the gate actually ran for
            // this session. Absence is the canonical "no gating data"
            // signal that TranscriptionSession checks for.
            if let gateFile, !gateFile.muted.isEmpty {
                do {
                    try gateFile.write(to: folder)
                    NSLog("[Meeting/Session] mic_gate.json written: %d intervals, %.1fs muted total",
                          gateFile.muted.count, gateFile.totalMutedDuration)
                } catch {
                    NSLog("[Meeting/Session] mic_gate.json write failed: %@",
                          String(describing: error))
                }
            }

            // meet_participants.json — only written if the AX scraper
            // captured at least one tile name during the session. Empty
            // file is the same as no file from the consumer's POV; we
            // skip the disk hit.
            if !participantNames.isEmpty {
                do {
                    try MeetParticipantsFile(participants: participantNames).write(to: folder)
                    NSLog("[Meeting/Session] meet_participants.json written: %d names",
                          participantNames.count)
                } catch {
                    NSLog("[Meeting/Session] meet_participants.json write failed: %@",
                          String(describing: error))
                }
            }

            // Persist the attached calendar event (if any) so the Library
            // can surface attendees / organizer / conference URL even
            // after the app restarts. Failure is non-fatal — the event
            // is just a metadata enrichment.
            if let event = currentEvent {
                do {
                    try CalendarEventFile(event: event).write(to: folder)
                } catch {
                    NSLog("[Meeting/Session] calendar.json write failed: %@",
                          String(describing: error))
                }
            }

            // context.json — clipboard + browser-URL items captured
            // during the session. Skip the disk hit when nothing was
            // captured; absence of the file is the canonical "no
            // context" signal that the Library / Transcript views
            // already check for.
            if !capturedContext.isEmpty {
                do {
                    try ContextCaptureFile(items: capturedContext).write(to: folder)
                    NSLog("[Meeting/Session] context.json written: %d items",
                          capturedContext.count)
                } catch {
                    NSLog("[Meeting/Session] context.json write failed: %@",
                          String(describing: error))
                }
            }
        }

        lastFolder = currentFolder
        currentFolder = nil
        currentSourceTitle = nil
        currentSourceApp = nil
        currentEvent = nil
        micDeviceName = nil
        tapProcessCount = 0
        state = .idle
    }

    private static func createFolder(in baseDir: URL) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let baseName = formatter.string(from: Date())

        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)

        var folder = baseDir.appendingPathComponent(baseName, isDirectory: true)
        var suffix = 2
        while FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)) {
            folder = baseDir.appendingPathComponent("\(baseName)-\(suffix)", isDirectory: true)
            suffix += 1
        }

        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}
