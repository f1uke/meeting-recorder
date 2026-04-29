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
    /// User-flagged moments accumulated by ⌘B during the active recording.
    /// Cleared on `start`, persisted to `marks.json` on `stop`.
    @Published private(set) var marks: [Mark] = []
    /// Mic device label for the recording window's "You · mic" sub-label.
    @Published private(set) var micDeviceName: String?
    /// Number of audio process objects bridged by the output tap. Surfaced
    /// to confirm Electron multi-helper detection is wired up.
    @Published private(set) var tapProcessCount: Int = 0

    /// Live mic-level ring buffer — the popover and recording window read
    /// from this each frame to draw the user's waveform. Survives recorder
    /// restart by being owned at the session level.
    let micRMS = RMSRingBuffer(capacity: 96)
    /// Live meeting-output level ring buffer.
    let outputRMS = RMSRingBuffer(capacity: 96)

    private var coordinator: ScreenCaptureCoordinator?
    private var micRecorder: MicRecorder?
    private var processAudioTap: ProcessAudioTap?
    private var currentFolder: URL?

    var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    func start(window: SCWindow) async {
        guard state == .idle else {
            NSLog("[Meeting/Session] start: bail — state is %@, expected .idle",
                  String(describing: state))
            return
        }
        state = .starting
        errorMessage = nil
        marks = []
        micRMS.reset()
        outputRMS.reset()

        // Watchdog: if any step hangs for 45s, force back to .idle with
        // an actionable errorMessage. The await in `coord.start` /
        // `engine.start()` / `AudioDeviceStart` can stall on TCC
        // re-prompts that the user can't see.
        scheduleStartWatchdog()

        let folder: URL
        do {
            folder = try Self.createFolder()
            NSLog("[Meeting/Session] start: created folder %@",
                  folder.path(percentEncoded: false))
        } catch {
            failStart("ไม่สามารถสร้างโฟลเดอร์: \(error.localizedDescription)")
            return
        }
        currentFolder = folder

        let videoURL = folder.appendingPathComponent("video.mov")
        let micURL = folder.appendingPathComponent("mic.wav")
        let outputURL = folder.appendingPathComponent("output.wav")

        guard let app = window.owningApplication else {
            failStart("หน้าต่างที่เลือกไม่มี application owner")
            return
        }
        let targetPID = app.processID
        let bundleID = app.bundleIdentifier
        let appName = app.applicationName
        NSLog("[Meeting/Session] start: target app name=%@ bundleID=%@ pid=%d title=%@",
              appName, bundleID, targetPID, window.title ?? "(none)")

        // Step 1: screen capture.
        NSLog("[Meeting/Session] start: step 1 — SCStream.startCapture …")
        let coord = ScreenCaptureCoordinator()
        do {
            try await coord.start(window: window, videoURL: videoURL)
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
            try await Task.detached(priority: .userInitiated) {
                try mic.start(url: micURLLocal, rmsBuffer: micRMSLocal)
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

        // Step 3: per-process audio tap. CoreAudio HAL setup
        // (AudioHardwareCreateProcessTap / CreateAggregateDevice /
        // AudioDeviceStart) is sync and the slowest leg — off-main for
        // the same reason as step 2.
        NSLog("[Meeting/Session] start: step 3 — Core Audio Tap …")
        let tap = ProcessAudioTap()
        do {
            let outputURLLocal = outputURL
            let outputRMSLocal = outputRMS
            let bundleIDLocal = bundleID
            let pidLocal = targetPID
            try await Task.detached(priority: .userInitiated) {
                try tap.start(
                    targetPID: pidLocal,
                    targetBundleID: bundleIDLocal,
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

        currentSourceTitle = window.title
        currentSourceApp = appName
        state = .recording(folder: folder, started: Date())
        cancelStartWatchdog()
        NSLog("[Meeting/Session] start: ALL READY — state=recording")
    }

    /// User-facing escape hatch from the .starting state. Called by the
    /// "Cancel start" button in PopoverTransientView when the spinner
    /// has been showing for an unreasonably long time.
    func cancelStart() {
        NSLog("[Meeting/Session] cancelStart from state=%@",
              String(describing: state))
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

    /// Append a mark at the current elapsed time. Triggered by ⌘B or the
    /// "+ Mark" button. No-op if not recording.
    func mark() {
        guard case let .recording(_, started) = state else { return }
        let elapsed = Date().timeIntervalSince(started)
        marks.append(Mark(timestamp: elapsed))
    }

    func stop() async {
        guard case .recording = state else { return }
        state = .stopping

        // Stop audio sources first so their WAV trailers flush before we
        // tear down the recording session.
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

        // Persist marks before the folder reference is cleared so the
        // file lands beside the media. Always written (even if empty) so
        // the upcoming MeetingsLibrary watcher has a known artifact.
        if let folder = currentFolder {
            do {
                try MarksFile(marks: marks).write(to: folder)
            } catch {
                NSLog("[Meeting/Session] marks.json write failed: %@",
                      String(describing: error))
            }
        }

        lastFolder = currentFolder
        currentFolder = nil
        currentSourceTitle = nil
        currentSourceApp = nil
        micDeviceName = nil
        tapProcessCount = 0
        state = .idle
    }

    private static func createFolder() throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let baseName = formatter.string(from: Date())

        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let baseDir = documents.appendingPathComponent("Meetings", isDirectory: true)

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
