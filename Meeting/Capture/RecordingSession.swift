import Foundation
import ScreenCaptureKit
import AVFoundation
import Combine

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
        guard state == .idle else { return }
        state = .starting
        errorMessage = nil
        marks = []
        micRMS.reset()
        outputRMS.reset()

        let folder: URL
        do {
            folder = try Self.createFolder()
        } catch {
            errorMessage = "ไม่สามารถสร้างโฟลเดอร์: \(error.localizedDescription)"
            state = .idle
            return
        }
        currentFolder = folder

        let videoURL = folder.appendingPathComponent("video.mov")
        let micURL = folder.appendingPathComponent("mic.wav")
        let outputURL = folder.appendingPathComponent("output.wav")

        guard let app = window.owningApplication else {
            errorMessage = "หน้าต่างที่เลือกไม่มี application owner"
            state = .idle
            currentFolder = nil
            return
        }
        let targetPID = app.processID
        NSLog("[Meeting/Session] target app: name=%@ bundleID=%@ pid=%d title=%@",
              app.applicationName,
              app.bundleIdentifier,
              targetPID,
              window.title ?? "(none)")

        let coord = ScreenCaptureCoordinator()
        do {
            try await coord.start(window: window, videoURL: videoURL)
            self.coordinator = coord
        } catch {
            errorMessage = "ScreenCapture เริ่มไม่ได้: \(error.localizedDescription)"
            state = .idle
            currentFolder = nil
            return
        }

        let mic = MicRecorder()
        do {
            try mic.start(url: micURL, rmsBuffer: micRMS)
            self.micRecorder = mic
            self.micDeviceName = mic.deviceName
        } catch {
            try? await coord.stop()
            self.coordinator = nil
            errorMessage = "Microphone เริ่มไม่ได้: \(error.localizedDescription)"
            state = .idle
            currentFolder = nil
            return
        }

        let tap = ProcessAudioTap()
        do {
            try tap.start(
                targetPID: targetPID,
                targetBundleID: app.bundleIdentifier,
                url: outputURL,
                rmsBuffer: outputRMS
            )
            self.processAudioTap = tap
            self.tapProcessCount = tap.processCount
        } catch {
            mic.stop()
            self.micRecorder = nil
            try? await coord.stop()
            self.coordinator = nil
            errorMessage = "Process audio tap เริ่มไม่ได้: \(error.localizedDescription)"
            state = .idle
            currentFolder = nil
            return
        }

        currentSourceTitle = window.title
        currentSourceApp = app.applicationName
        state = .recording(folder: folder, started: Date())
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
