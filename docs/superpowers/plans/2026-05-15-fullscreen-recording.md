# Full-screen recording — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user choose a whole display as the capture source instead of a single window. When a display is chosen, `ProcessAudioTap` runs in a new `.system` mode (whole-system tap), and bundle-ID-dependent integrations (MicGate, Meet participants scraper) are skipped. The transcribe / merger / library pipeline downstream is unchanged.

**Architecture:** Introduce a `CaptureSource` enum (`.window(SCWindow) | .display(SCDisplay)`) that flows through `WindowPickerModel` → `RecordingSession.start(source:event:)` → `ScreenCaptureCoordinator` and `ProcessAudioTap`. `ProcessAudioTap` gains a `TapTarget` enum so the existing per-process path stays untouched while a `.system` branch uses `CATapDescription(stereoGlobalTapButExcludeProcesses: [self])`. The picker UI renders a new "Displays" group above existing app groups; row clicks set `selectedSource = .display(displayID)` via the same deferred-binding pattern that windows use.

**Tech Stack:** Swift 6, SwiftUI, ScreenCaptureKit (`SCShareableContent`, `SCContentFilter`, `SCDisplay`, `SCStream`), Core Audio (`CATapDescription`, `AudioHardwareCreateProcessTap`, aggregate device), AppKit (`NSScreen.localizedName` lookup), XCTest.

**Reference spec:** `docs/superpowers/specs/2026-05-15-fullscreen-recording-design.md`

---

## Task 1: `CaptureSource` enum + display naming helper

**Files:**
- Create: `Meeting/Capture/CaptureSource.swift`
- Create: `MeetingTests/CaptureSourceTests.swift`
- Modify: `project.yml` is NOT needed — XcodeGen auto-discovers new `.swift` files (but we'll regenerate later in Task 9).

- [ ] **Step 1: Write the failing test**

`MeetingTests/CaptureSourceTests.swift`:

```swift
import XCTest
import ScreenCaptureKit
@testable import Meeting

final class CaptureSourceTests: XCTestCase {
    func test_displayLabel_primary_includesSuffix() {
        // CGMainDisplayID() always exists in test host.
        let mainID = CGMainDisplayID()
        let label = CaptureSource.displayLabel(displayID: mainID)
        XCTAssertTrue(label.hasSuffix(" (primary)"),
                      "primary display should suffix '(primary)', got: \(label)")
    }

    func test_displayLabel_unknownID_fallsBackToIndex() {
        // Synthetic ID guaranteed not to match any NSScreen.
        let bogusID: CGDirectDisplayID = 0xDEADBEEF
        let label = CaptureSource.displayLabel(displayID: bogusID)
        XCTAssertTrue(label.hasPrefix("Display "),
                      "unknown displayID should fall back to 'Display N', got: \(label)")
    }
}
```

- [ ] **Step 2: Run test — it should fail because `CaptureSource` does not exist**

```bash
xcodebuild -project Meeting.xcodeproj -scheme Meeting -destination 'platform=macOS' \
  -only-testing:MeetingTests/CaptureSourceTests test 2>&1 | tail -20
```

Expected: build failure — `cannot find 'CaptureSource' in scope`.

- [ ] **Step 3: Write `CaptureSource.swift`**

`Meeting/Capture/CaptureSource.swift`:

```swift
import Foundation
import ScreenCaptureKit
import AppKit

/// The thing the user picked to record. Drives:
///   - SCContentFilter shape in ScreenCaptureCoordinator
///   - ProcessAudioTap mode (per-process vs system-wide)
///   - Which bundle-ID-dependent integrations (MicGate, Meet scraper) run
///   - Recording header labels in PopoverRecordingView
enum CaptureSource {
    case window(SCWindow)
    case display(SCDisplay)

    /// Pretty title for the recording header's primary slot.
    /// Mirrors `win.title` for the window path; for displays we emit a
    /// fixed string and put the device name in `app`.
    var title: String {
        switch self {
        case .window(let w):
            return w.title ?? "Untitled Window"
        case .display:
            return "Screen Recording"
        }
    }

    /// App / device label for the recording header's secondary slot.
    var app: String {
        switch self {
        case .window(let w):
            return w.owningApplication?.applicationName ?? "Unknown"
        case .display(let d):
            return Self.displayLabel(displayID: d.displayID)
        }
    }

    /// Bundle ID for downstream integrations. `nil` for display sources —
    /// callers must treat nil as "skip integrations that need it"
    /// (MicGate, Meet scraper, per-process audio tap target).
    var bundleID: String? {
        switch self {
        case .window(let w):
            return w.owningApplication?.bundleIdentifier
        case .display:
            return nil
        }
    }

    /// PID for downstream integrations. `nil` for display sources.
    var pid: pid_t? {
        switch self {
        case .window(let w):
            return w.owningApplication?.processID
        case .display:
            return nil
        }
    }

    /// Human-readable display label, e.g.
    /// "Built-in Retina Display (primary)" or "DELL U2723QE".
    /// Falls back to "Display N" indexed by `NSScreen.screens` order
    /// when the displayID is unknown to AppKit.
    static func displayLabel(displayID: CGDirectDisplayID) -> String {
        let screens = NSScreen.screens
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        let matched = screens.first { screen in
            (screen.deviceDescription[key] as? CGDirectDisplayID) == displayID
        }
        let name: String
        if let matched, !matched.localizedName.isEmpty {
            name = matched.localizedName
        } else {
            // Index fallback when AppKit doesn't know this display
            // (rare: virtual display, race during hot-plug).
            let idx = screens.firstIndex { screen in
                (screen.deviceDescription[key] as? CGDirectDisplayID) == displayID
            }
            name = "Display \((idx ?? 0) + 1)"
        }
        if displayID == CGMainDisplayID() {
            return "\(name) (primary)"
        }
        return name
    }
}
```

- [ ] **Step 4: Regenerate project so xcodebuild sees the new file**

```bash
cd /Users/fluke/Documents/Projects/meeting && xcodegen generate
```

Expected: prints "Generated project successfully".

- [ ] **Step 5: Run tests — both should pass**

```bash
xcodebuild -project Meeting.xcodeproj -scheme Meeting -destination 'platform=macOS' \
  -only-testing:MeetingTests/CaptureSourceTests test 2>&1 | tail -10
```

Expected: `Test Suite 'CaptureSourceTests' passed`.

- [ ] **Step 6: Commit**

```bash
git add Meeting/Capture/CaptureSource.swift MeetingTests/CaptureSourceTests.swift
git commit -m "$(cat <<'EOF'
CaptureSource — enum that wraps SCWindow or SCDisplay

Adds the shared abstraction the picker, RecordingSession, and capture
coordinators will all key off. displayLabel maps CGDirectDisplayID
back to NSScreen.localizedName and tags primary.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: `ProcessAudioTap` — add `.system` target

**Files:**
- Modify: `Meeting/Capture/ProcessAudioTap.swift` — add `TapTarget` enum, refactor `start(...)` signature
- Modify: `Meeting/Capture/RecordingSession.swift:170-179` — call site (just the `try tap.start(...)` block; we'll do the broader Session refactor in Task 4)

- [ ] **Step 1: Add `TapTarget` enum and refactor `start(...)`**

In `Meeting/Capture/ProcessAudioTap.swift`, replace lines 17-143 (class body up through end of `start(...)`):

```swift
final class ProcessAudioTap: @unchecked Sendable {
    enum TapTarget {
        /// Per-process tap (current path). Includes Electron multi-helper
        /// discovery via bundle-ID prefix scan.
        case process(pid: pid_t, bundleID: String)
        /// Whole-system tap. Excludes our own audio process to prevent
        /// feedback with Meeting's UI sounds.
        case system
    }

    private var processTapID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var deviceProcID: AudioDeviceIOProcID?
    private var fileBox: AudioFileBox?
    private let queue = DispatchQueue(label: "dev.fluke.meeting.process-tap", qos: .userInitiated)
    /// Number of audio process objects this tap is bridging. For `.process`
    /// targets, typically 1 for native apps and 2-4+ for Electron/Chromium.
    /// For `.system`, reports 0 (count is not meaningful — every process is
    /// tapped).
    private(set) var processCount: Int = 0

    func start(target: TapTarget, url: URL, rmsBuffer: RMSRingBuffer? = nil) throws {
        let tapDescription: CATapDescription
        let aggregateName: String

        switch target {
        case .process(let pid, let bundleID):
            // Electron / Chromium apps produce audio in helper processes
            // whose PID differs from the main window's. Tap every audio
            // process whose bundleID shares a prefix with the main app.
            let processObjectIDs = Self.collectAudioObjectIDs(
                mainPID: pid,
                bundleIDPrefix: bundleID
            )
            guard !processObjectIDs.isEmpty else {
                throw TapError.translatePID(pid, OSStatus(kAudioHardwareBadObjectError))
            }
            self.processCount = processObjectIDs.count
            NSLog("[Meeting/Tap] start .process pid=%d bundle=%@ → tapping %d audio object(s): %@",
                  pid, bundleID, processObjectIDs.count,
                  processObjectIDs.map { String($0) }.joined(separator: ","))
            tapDescription = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
            aggregateName = "MeetingTap-\(pid)"

        case .system:
            // Whole-system tap. Best-effort exclude our own audio process
            // so the tap doesn't pick up Meeting's UI sounds; if AppKit
            // hasn't surfaced our process to the HAL yet (no audio played),
            // we pass [] which is fine — fully global.
            let selfExclude = Self.selfProcessAudioObjectIDs()
            self.processCount = 0
            NSLog("[Meeting/Tap] start .system → excluding self audio objects: %@",
                  selfExclude.map { String($0) }.joined(separator: ","))
            tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: selfExclude)
            aggregateName = "MeetingTap-system"
        }

        tapDescription.uuid = UUID()
        tapDescription.muteBehavior = .unmuted

        var tapID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
        var err = AudioHardwareCreateProcessTap(tapDescription, &tapID)
        guard err == noErr else { throw TapError.create(err) }
        processTapID = tapID
        NSLog("[Meeting/Tap] created tap=%u", tapID)

        var asbd = try Self.readTapStreamFormat(tapID: tapID)
        NSLog("[Meeting/Tap] asbd rate=%.0f ch=%u flags=0x%x bytesPerFrame=%u",
              asbd.mSampleRate, asbd.mChannelsPerFrame, asbd.mFormatFlags, asbd.mBytesPerFrame)
        guard let format = AVAudioFormat(streamDescription: &asbd) else {
            throw TapError.formatUnavailable
        }
        NSLog("[Meeting/Tap] avFormat common=%d interleaved=%d", format.commonFormat.rawValue, format.isInterleaved ? 1 : 0)

        let outputDeviceID = try Self.readDefaultSystemOutputDevice()
        let outputUID = try Self.readDeviceUID(deviceID: outputDeviceID)

        let aggregateUID = UUID().uuidString
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: aggregateName,
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
                ]
            ],
        ]

        var aggID = AudioObjectID(kAudioObjectUnknown)
        err = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggID)
        guard err == noErr else { throw TapError.aggregate(err) }
        aggregateDeviceID = aggID

        let aggRate = (try? Self.readDeviceNominalSampleRate(deviceID: aggID)) ?? format.sampleRate
        let deliveryFormat: AVAudioFormat = {
            guard aggRate > 0, abs(aggRate - format.sampleRate) > 0.5 else { return format }
            NSLog("[Meeting/Tap] rate mismatch: tap=%.0f agg=%.0f — using aggregate rate",
                  format.sampleRate, aggRate)
            return AVAudioFormat(
                commonFormat: format.commonFormat,
                sampleRate: aggRate,
                channels: format.channelCount,
                interleaved: format.isInterleaved
            ) ?? format
        }()

        let fileSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: deliveryFormat.sampleRate,
            AVNumberOfChannelsKey: deliveryFormat.channelCount,
            AVEncoderBitRateKey: 96_000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let file = try AVAudioFile(
            forWriting: url,
            settings: fileSettings,
            commonFormat: deliveryFormat.commonFormat,
            interleaved: deliveryFormat.isInterleaved
        )
        let box = AudioFileBox(file: file, format: deliveryFormat, rmsBuffer: rmsBuffer)
        fileBox = box

        var procID: AudioDeviceIOProcID?
        err = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, queue) { [box] _, inputData, inputTime, _, _ in
            box.handleInput(bufferList: inputData, inputTime: inputTime)
        }
        guard err == noErr else { throw TapError.ioProc(err) }
        deviceProcID = procID
        NSLog("[Meeting/Tap] IOProc registered, starting device")

        err = AudioDeviceStart(aggID, procID)
        guard err == noErr else { throw TapError.start(err) }
        NSLog("[Meeting/Tap] AudioDeviceStart OK — waiting for audio frames")
    }
```

- [ ] **Step 2: Add `selfProcessAudioObjectIDs()` helper**

In the same file, add this as a new `private static` method below `collectAudioObjectIDs(...)` (around line 197, just before `readAllAudioProcessObjectIDs`):

```swift
    /// Returns the audio process object IDs that belong to *this* app —
    /// every helper / main-PID combination where the bundleID matches our
    /// own. Used by `.system` tap mode to exclude self from the mixdown.
    /// Returns [] when our app has not played any audio yet (HAL has no
    /// process object for us). Empty exclusion → fully global tap, which
    /// is acceptable.
    private static func selfProcessAudioObjectIDs() -> [AudioObjectID] {
        let ourPID = ProcessInfo.processInfo.processIdentifier
        let ourBundleID = Bundle.main.bundleIdentifier ?? ""
        // Reuse the same prefix-scan logic the per-process path uses — if
        // Meeting ever ships helpers, they'd be excluded too.
        return collectAudioObjectIDs(mainPID: ourPID, bundleIDPrefix: ourBundleID)
    }
```

- [ ] **Step 3: Update the RecordingSession call site (minimal patch)**

In `Meeting/Capture/RecordingSession.swift`, replace lines 167-179 (`let tap = ProcessAudioTap()` through the `.value`) with:

```swift
        let tap = ProcessAudioTap()
        do {
            let outputURLLocal = outputURL
            let outputRMSLocal = outputRMS
            let bundleIDLocal = bundleID
            let pidLocal = targetPID
            try await Task.detached(priority: .userInitiated) {
                try tap.start(
                    target: .process(pid: pidLocal, bundleID: bundleIDLocal),
                    url: outputURLLocal,
                    rmsBuffer: outputRMSLocal
                )
            }.value
```

This is a behavior-preserving refactor — same `.process` path, new signature.

- [ ] **Step 4: Build to confirm refactor compiles**

```bash
xcodebuild -project Meeting.xcodeproj -scheme Meeting -configuration Debug \
  -destination 'platform=macOS' build 2>&1 | tail -20
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Run existing test suite to confirm no regressions**

```bash
pkill -9 -f "Meeting.app" 2>/dev/null; \
xcodebuild -project Meeting.xcodeproj -scheme Meeting -destination 'platform=macOS' test 2>&1 | tail -20
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add Meeting/Capture/ProcessAudioTap.swift Meeting/Capture/RecordingSession.swift
git commit -m "$(cat <<'EOF'
ProcessAudioTap — accept TapTarget (.process | .system)

.system uses CATapDescription(stereoGlobalTapButExcludeProcesses:),
excluding our own audio process to prevent UI-sound feedback.
RecordingSession call site updated to pass .process explicitly;
behavior unchanged.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: `ScreenCaptureCoordinator` — accept `CaptureSource`

**Files:**
- Modify: `Meeting/Capture/ScreenCaptureCoordinator.swift:15-53` — `start(source:videoURL:)`
- Modify: `Meeting/Capture/RecordingSession.swift:115` — call site

- [ ] **Step 1: Refactor `start(source:videoURL:)`**

Replace the `start(window:videoURL:)` method body with:

```swift
    func start(source: CaptureSource, videoURL: URL) async throws {
        let filter: SCContentFilter
        let captureSize: CGSize

        switch source {
        case .window(let window):
            filter = SCContentFilter(desktopIndependentWindow: window)
            captureSize = window.frame.size

        case .display(let display):
            // Exclude our own app from the captured surface so the
            // popover / future recording window doesn't appear in the
            // video. Using exceptingWindows:[] means we exclude *all*
            // of self's windows, not just specific ones.
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )
            let ownPID = ProcessInfo.processInfo.processIdentifier
            let selfApps = content.applications.filter { $0.processID == ownPID }
            filter = SCContentFilter(
                display: display,
                excludingApplications: selfApps,
                exceptingWindows: []
            )
            captureSize = display.frame.size
        }

        let config = SCStreamConfiguration()
        config.width = max(2, Int(captureSize.width))
        config.height = max(2, Int(captureSize.height))
        config.minimumFrameInterval = CMTime(value: 1, timescale: 10)
        config.queueDepth = 8
        config.capturesAudio = false
        config.captureMicrophone = false
        config.showsCursor = true
        config.pixelFormat = kCVPixelFormatType_32BGRA

        let stream = SCStream(filter: filter, configuration: config, delegate: streamDelegate)

        let recConfig = SCRecordingOutputConfiguration()
        recConfig.outputURL = videoURL
        recConfig.outputFileType = .mov
        recConfig.videoCodecType = .hevc

        let recOutput = SCRecordingOutput(configuration: recConfig, delegate: recordingOutputDelegate)
        try stream.addRecordingOutput(recOutput)
        try stream.addStreamOutput(frameSink, type: .screen, sampleHandlerQueue: frameQueue)

        try await stream.startCapture()

        self.stream = stream
        self.recordingOutput = recOutput
    }
```

- [ ] **Step 2: Update `RecordingSession` call site (minimal patch)**

In `Meeting/Capture/RecordingSession.swift` line ~115, change:

```swift
            try await coord.start(window: window, videoURL: videoURL)
```

to:

```swift
            try await coord.start(source: .window(window), videoURL: videoURL)
```

(The `.display` path comes in Task 4 — for now this is a behavior-preserving refactor.)

- [ ] **Step 3: Build to confirm**

```bash
xcodebuild -project Meeting.xcodeproj -scheme Meeting -configuration Debug \
  -destination 'platform=macOS' build 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add Meeting/Capture/ScreenCaptureCoordinator.swift Meeting/Capture/RecordingSession.swift
git commit -m "$(cat <<'EOF'
ScreenCaptureCoordinator — accept CaptureSource

.display path uses SCContentFilter(display:excludingApplications:
exceptingWindows:) with self's applications excluded so the captured
video does not contain Meeting's own UI. Window path unchanged.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: `RecordingSession.start(source:event:)` with display-path toggles

**Files:**
- Modify: `Meeting/Capture/RecordingSession.swift` — change signature, route by source

- [ ] **Step 1: Change the `start` signature and reshape the body**

Replace the entire `func start(window:event:)` (lines 68-254) with:

```swift
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
        // (mic gate, Meet scraper) that depend on bundle ID / PID; display
        // mode skips them.
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

        // Step 2: mic — unchanged from window path.
        NSLog("[Meeting/Session] start: step 2 — AVAudioEngine input tap …")
        let mic = MicRecorder()
        do {
            let micURLLocal = micURL
            let micRMSLocal = micRMS
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

        // Step 3: per-process or system audio tap.
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

        // Step 4: mic gate — window/bundleID-dependent; skip for display.
        if let bundle = sourceBundleID, let pid = sourcePID,
           let gate = MicGate.create(forBundleID: bundle, pid: pid) {
            gate.start(sessionStart: recordingStart)
            self.micGate = gate
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

        // Step 5: Meet participants scrape — Chrome window only.
        if sourceBundleID == "com.google.Chrome", let pid = sourcePID, AXIsProcessTrusted() {
            let collector = MeetParticipantsCollector(pid: pid)
            collector.start()
            self.meetParticipants = collector
            NSLog("[Meeting/Session] start: step 5 done — MeetParticipantsCollector active")
        }

        // Step 6: context watchers — unchanged for both paths.
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
```

- [ ] **Step 2: Build to confirm**

```bash
xcodebuild -project Meeting.xcodeproj -scheme Meeting -configuration Debug \
  -destination 'platform=macOS' build 2>&1 | tail -20
```

Expected: build fails at the call site in `PopoverViews.swift:148` (`recording.start(window:event:)` no longer exists). That's the point — we'll fix it in Task 8 after the picker is ready. For now, **temporarily** add a shim so the build passes:

```swift
    // Temporary compat shim — removed in Task 8 when the call site
    // migrates to start(source:event:).
    func start(window: SCWindow, event: CalendarEvent? = nil) async {
        await start(source: .window(window), event: event)
    }
```

Add this method directly below the new `start(source:event:)`.

- [ ] **Step 3: Build to confirm with shim**

```bash
xcodebuild -project Meeting.xcodeproj -scheme Meeting -configuration Debug \
  -destination 'platform=macOS' build 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Run tests**

```bash
pkill -9 -f "Meeting.app" 2>/dev/null; \
xcodebuild -project Meeting.xcodeproj -scheme Meeting -destination 'platform=macOS' test 2>&1 | tail -20
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add Meeting/Capture/RecordingSession.swift
git commit -m "$(cat <<'EOF'
RecordingSession.start(source:event:) — display path

Routes the screen-capture / audio-tap configuration by CaptureSource.
MicGate and Meet scraper run only when sourceBundleID is non-nil. Old
start(window:event:) kept as a temporary shim until the picker call
site is migrated.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: `WindowPickerModel` — surface displays and `selectedCaptureSource`

**Files:**
- Modify: `Meeting/Capture/WindowPicker.swift` — model section (lines 5-88)
- Create: `MeetingTests/WindowPickerModelTests.swift`

- [ ] **Step 1: Write the failing tests**

`MeetingTests/WindowPickerModelTests.swift`:

```swift
import XCTest
import ScreenCaptureKit
@testable import Meeting

@MainActor
final class WindowPickerModelTests: XCTestCase {
    func test_selectedCaptureSource_nil_whenNoSelection() {
        let model = WindowPickerModel()
        XCTAssertNil(model.selectedCaptureSource)
    }

    func test_selectedCaptureSource_resolvesDisplay() async {
        let model = WindowPickerModel()
        // Inject a synthetic SCDisplay via the internal seam used by tests.
        // (We seed an in-memory display list — refresh() can't run in unit
        // tests because SCShareableContent needs the running app + TCC.)
        let mainID = CGMainDisplayID()
        model._seedForTests(windows: [], displays: [TestDisplay(id: mainID)])
        model.selectedSource = .display(mainID)
        guard case .display(let disp) = model.selectedCaptureSource else {
            return XCTFail("expected .display, got \(String(describing: model.selectedCaptureSource))")
        }
        XCTAssertEqual(disp.displayID, mainID)
    }

    func test_selectedCaptureSource_clearedWhenDisplayDisappears() {
        let model = WindowPickerModel()
        let mainID = CGMainDisplayID()
        model._seedForTests(windows: [], displays: [TestDisplay(id: mainID)])
        model.selectedSource = .display(mainID)

        // Display unplugged on a subsequent refresh.
        model._seedForTests(windows: [], displays: [])
        XCTAssertNil(model.selectedSource,
                     "selection should clear when its display vanishes")
    }
}

/// Stand-in for SCDisplay in tests; the model treats displays
/// only by their `displayID`, so this is enough.
private struct TestDisplay {
    let id: CGDirectDisplayID
}
```

- [ ] **Step 2: Run tests — should fail because `_seedForTests` does not exist**

```bash
xcodebuild -project Meeting.xcodeproj -scheme Meeting -destination 'platform=macOS' \
  -only-testing:MeetingTests/WindowPickerModelTests test 2>&1 | tail -10
```

Expected: build failure — `value of type 'WindowPickerModel' has no member '_seedForTests'`.

- [ ] **Step 3: Extend `WindowPickerModel`**

Replace lines 5-88 of `Meeting/Capture/WindowPicker.swift` (the entire `WindowPickerModel` class) with:

```swift
/// What the user selected in the source picker — either a specific
/// window or an entire display. Hashable so it can drive selection
/// state without holding references to SCWindow/SCDisplay (which
/// turn over each refresh).
enum PickerSource: Hashable {
    case window(CGWindowID)
    case display(CGDirectDisplayID)
}

@MainActor
final class WindowPickerModel: ObservableObject {
    @Published private(set) var windows: [SCWindow] = []
    @Published private(set) var displays: [SCDisplay] = []
    @Published var selectedSource: PickerSource?
    @Published private(set) var isLoading = false
    @Published private(set) var loadError: String?

    private var iconCache: [pid_t: NSImage] = [:]

    /// Resolves the selection to a concrete `CaptureSource` if the
    /// picked window / display is still present in the latest scan.
    var selectedCaptureSource: CaptureSource? {
        switch selectedSource {
        case .window(let id):
            return windows.first { $0.windowID == id }.map { .window($0) }
        case .display(let id):
            return displays.first { $0.displayID == id }.map { .display($0) }
        case .none:
            return nil
        }
    }

    func icon(for window: SCWindow) -> NSImage? {
        guard let pid = window.owningApplication?.processID else { return nil }
        if let cached = iconCache[pid] { return cached }
        let img = NSRunningApplication(processIdentifier: pid)?.icon
        if let img { iconCache[pid] = img }
        return img
    }

    func refresh() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                true,
                onScreenWindowsOnly: true
            )
            let myPID = ProcessInfo.processInfo.processIdentifier
            let filtered = content.windows.filter { Self.shouldShow($0, ownPID: myPID) }

            self.windows = filtered.sorted {
                let a = $0.owningApplication?.applicationName ?? ""
                let b = $1.owningApplication?.applicationName ?? ""
                if a == b { return ($0.title ?? "") < ($1.title ?? "") }
                return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
            }

            // Displays are unfiltered — every available display is a
            // valid source. Sort with primary first, then by displayID
            // for stable ordering across refreshes.
            self.displays = content.displays.sorted { lhs, rhs in
                let lp = lhs.displayID == CGMainDisplayID()
                let rp = rhs.displayID == CGMainDisplayID()
                if lp != rp { return lp }
                return lhs.displayID < rhs.displayID
            }

            // Clear selection if its target is gone.
            clearStaleSelection()
        } catch {
            self.loadError = error.localizedDescription
        }
    }

    /// Test-only seam. Production code goes through `refresh()`, which
    /// can't run in unit tests because SCShareableContent requires the
    /// running app + Screen Recording TCC.
    func _seedForTests(windows: [SCWindow], displays: [Any]) {
        self.windows = windows
        // We accept `[Any]` so tests can pass a stand-in struct that
        // exposes a `displayID` without subclassing SCDisplay (which
        // refuses inheritance). Production never calls this.
        self.displays = displays.compactMap { $0 as? SCDisplay }
        // For tests using stand-in structs (TestDisplay), the cast
        // returns nil — we instead match selection-clearing logic by
        // ID alone via `_seedDisplayIDs`.
        let ids: [CGDirectDisplayID] = displays.compactMap { item in
            if let d = item as? SCDisplay { return d.displayID }
            // Reflect to read `id` from arbitrary struct.
            let mirror = Mirror(reflecting: item)
            for child in mirror.children where child.label == "id" {
                if let v = child.value as? CGDirectDisplayID { return v }
            }
            return nil
        }
        self._seededDisplayIDs = ids
        clearStaleSelection()
    }
    private var _seededDisplayIDs: [CGDirectDisplayID] = []

    private func clearStaleSelection() {
        switch selectedSource {
        case .window(let id):
            if !windows.contains(where: { $0.windowID == id }) {
                selectedSource = nil
            }
        case .display(let id):
            // Honor either real displays or test-seeded IDs.
            let liveIDs: Set<CGDirectDisplayID> =
                Set(displays.map { $0.displayID }).union(_seededDisplayIDs)
            if !liveIDs.contains(id) {
                selectedSource = nil
            }
        case .none:
            break
        }
    }

    private static let blockedBundlePrefixes: Set<String> = [
        "com.apple.dock",
        "com.apple.controlcenter",
        "com.apple.notificationcenter",
        "com.apple.systemuiserver",
        "com.apple.WindowManager",
        "com.apple.loginwindow",
        "com.apple.coreservices",
        "com.apple.WebKit",
        "com.apple.Spotlight",
        "com.apple.wallpaper",
    ]

    private static func shouldShow(_ window: SCWindow, ownPID: pid_t) -> Bool {
        guard let app = window.owningApplication else { return false }
        if app.processID == ownPID { return false }
        if window.windowLayer != 0 { return false }
        if window.frame.width < 100 || window.frame.height < 100 { return false }
        let appName = app.applicationName.trimmingCharacters(in: .whitespaces)
        if appName.isEmpty { return false }
        let bundleID = app.bundleIdentifier
        if Self.blockedBundlePrefixes.contains(where: { bundleID.hasPrefix($0) }) {
            return false
        }
        let title = (window.title ?? "").trimmingCharacters(in: .whitespaces)
        if title.isEmpty { return false }
        return true
    }
}
```

- [ ] **Step 4: Run picker tests — should pass**

```bash
xcodebuild -project Meeting.xcodeproj -scheme Meeting -destination 'platform=macOS' \
  -only-testing:MeetingTests/WindowPickerModelTests test 2>&1 | tail -10
```

Expected: `Test Suite 'WindowPickerModelTests' passed`.

- [ ] **Step 5: Commit**

```bash
git add Meeting/Capture/WindowPicker.swift MeetingTests/WindowPickerModelTests.swift
git commit -m "$(cat <<'EOF'
WindowPickerModel — add displays and PickerSource selection

Replaces selectedWindowID with selectedSource (PickerSource enum:
.window(CGWindowID) | .display(CGDirectDisplayID)). selectedCaptureSource
resolves to a CaptureSource that the recording session consumes.
refresh() now loads both windows and displays from one
SCShareableContent call.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: `WindowPicker` view — render Displays group

**Files:**
- Modify: `Meeting/Capture/WindowPicker.swift` — view section (lines 90-252)

- [ ] **Step 1: Update the `WindowPicker` view body**

Replace the `var body: some View` of `WindowPicker` (and the helper `groupedByApp()`) with:

```swift
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if model.isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    let total = model.windows.count + model.displays.count
                    Text("\(total) sources")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.textFaint)
                }
                Spacer()
                Button {
                    Task { await model.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.brandAccent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Refresh source list")
            }

            if let error = model.loadError {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.system(size: 10))
            }

            ScrollView(showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if !model.displays.isEmpty {
                        DisplaysHeader(count: model.displays.count)
                            .padding(.top, 4)
                        ForEach(model.displays, id: \.displayID) { display in
                            DisplayRow(
                                display: display,
                                isSelected: model.selectedSource == .display(display.displayID),
                                onSelect: {
                                    model.selectedSource = .display(display.displayID)
                                }
                            )
                        }
                    }
                    ForEach(groupedByApp(), id: \.appName) { group in
                        AppHeader(group: group, model: model)
                            .padding(.top, 4)
                        ForEach(group.windows, id: \.windowID) { window in
                            WindowRow(
                                window: window,
                                isSelected: model.selectedSource == .window(window.windowID),
                                onSelect: {
                                    model.selectedSource = .window(window.windowID)
                                }
                            )
                        }
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 4)
            }
            .frame(height: 180)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
                    }
            }
        }
        .task {
            if model.windows.isEmpty && model.displays.isEmpty {
                await model.refresh()
            }
        }
    }

    private func groupedByApp() -> [AppGroup] {
        let grouped = Dictionary(grouping: model.windows) { window in
            window.owningApplication?.applicationName ?? "Unknown"
        }
        return grouped
            .map { AppGroup(appName: $0.key, windows: $0.value) }
            .sorted { $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending }
    }
```

- [ ] **Step 2: Add `DisplaysHeader` and `DisplayRow`**

Append these private views to `Meeting/Capture/WindowPicker.swift` (after `WindowRow`):

```swift
private struct DisplaysHeader: View {
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "display")
                .resizable()
                .interpolation(.high)
                .frame(width: 14, height: 14)
                .foregroundStyle(Color.brandAccent)
            Text("Displays")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.textPrimary)
            Text("(\(count))")
                .font(.system(size: 10))
                .foregroundStyle(Color.textFaint)
            Spacer()
        }
        .padding(.horizontal, 6)
    }
}

private struct DisplayRow: View {
    let display: SCDisplay
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 6) {
                Spacer().frame(width: 18)
                Text(CaptureSource.displayLabel(displayID: display.displayID))
                    .font(.system(size: 11))
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Text(dimensions)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(Color.textFaint)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.brandAccent)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.brandAccent.opacity(0.14))
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var dimensions: String {
        "\(Int(display.frame.width))×\(Int(display.frame.height))"
    }
}
```

- [ ] **Step 3: Build to confirm**

```bash
xcodebuild -project Meeting.xcodeproj -scheme Meeting -configuration Debug \
  -destination 'platform=macOS' build 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add Meeting/Capture/WindowPicker.swift
git commit -m "$(cat <<'EOF'
WindowPicker — render Displays group at top of source list

DisplaysHeader + DisplayRow mirror AppHeader/WindowRow but key on
displayID. Selection state uses the same deferred-binding pattern
that windows use (Button.action setting model.selectedSource).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: `PopoverIdleView` — migrate to `selectedCaptureSource`

**Files:**
- Modify: `Meeting/App/PopoverViews.swift:63, 79, 134-149`
- Modify: `Meeting/Capture/RecordingSession.swift` — remove shim added in Task 4

- [ ] **Step 1: Update `PopoverIdleView` to use the new picker API**

In `Meeting/App/PopoverViews.swift`, find the `disabled` modifier on the Start Recording button (line ~63) and change:

```swift
            .disabled(picker.selectedWindow == nil)
```

to:

```swift
            .disabled(picker.selectedCaptureSource == nil)
```

In the same file, find `.onChange(of: picker.selectedWindow?.windowID)` (around line 79) and change to:

```swift
        .onChange(of: picker.selectedSource) { _, _ in
            autoPickEventIfNeeded()
        }
```

Replace `autoPickEventIfNeeded()` (around line 134) with:

```swift
    private func autoPickEventIfNeeded() {
        guard eventIsAutoSelected else { return }
        let bundleID: String?
        if case .window(let win) = picker.selectedCaptureSource {
            bundleID = win.owningApplication?.bundleIdentifier
        } else {
            bundleID = nil
        }
        let best = CalendarMatcher.bestMatch(
            events: calendar.relevantEvents,
            now: Date(),
            windowBundleID: bundleID
        )
        selectedEvent = best?.event
    }
```

Replace `startRecording()` (around line 145) with:

```swift
    private func startRecording() {
        guard let source = picker.selectedCaptureSource else { return }
        let event = selectedEvent
        Task { await recording.start(source: source, event: event) }
    }
```

- [ ] **Step 2: Remove the temporary `start(window:event:)` shim**

In `Meeting/Capture/RecordingSession.swift`, delete the shim added in Task 4 Step 2:

```swift
    // Temporary compat shim — removed in Task 8 when the call site
    // migrates to start(source:event:).
    func start(window: SCWindow, event: CalendarEvent? = nil) async {
        await start(source: .window(window), event: event)
    }
```

- [ ] **Step 3: Build to confirm**

```bash
xcodebuild -project Meeting.xcodeproj -scheme Meeting -configuration Debug \
  -destination 'platform=macOS' build 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Run full test suite**

```bash
pkill -9 -f "Meeting.app" 2>/dev/null; \
xcodebuild -project Meeting.xcodeproj -scheme Meeting -destination 'platform=macOS' test 2>&1 | tail -20
```

Expected: all tests pass (including the new CaptureSourceTests + WindowPickerModelTests).

- [ ] **Step 5: Commit**

```bash
git add Meeting/App/PopoverViews.swift Meeting/Capture/RecordingSession.swift
git commit -m "$(cat <<'EOF'
PopoverIdleView — start(source:event:); drop transition shim

Migrates the start button and auto-event-pick logic to the new
selectedCaptureSource API. Removes the temporary RecordingSession
shim that bridged the old start(window:event:) API.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Manual smoke validation

This task is human-verified. Do **not** mark steps complete until the human
confirms each smoke result.

**Files:** none modified.

- [ ] **Step 1: Build and launch the app**

```bash
xcodebuild -project Meeting.xcodeproj -scheme Meeting -configuration Debug \
  -destination 'platform=macOS' build 2>&1 | tail -5 && \
open ~/Library/Developer/Xcode/DerivedData/Meeting-*/Build/Products/Debug/Meeting.app
```

Or launch from Xcode (⌘R) to keep TCC continuity.

- [ ] **Step 2: Smoke — window source regression**

  1. Open Zoom (or any meeting app that's currently playing audio).
  2. Click the Meeting menu-bar icon; in the source picker, scroll past the
     new "Displays" group and pick the Zoom window.
  3. Press Start Recording. Speak for ~20 seconds.
  4. Press ⌘. to stop.
  5. Open `~/Documents/Meetings/<latest>/output.m4a` in QuickTime.

  Expected: contains only Zoom audio, not other system audio.
  Pre-existing behavior — confirms no regression.

- [ ] **Step 3: Smoke — display source, system audio**

  1. Click the Meeting menu-bar icon. In "Displays" group, pick the main
     display.
  2. Press Start Recording.
  3. Play a Spotify track and say "hello world" into the mic.
  4. Press ⌘. to stop.
  5. Open the new meeting's `output.m4a` in QuickTime.

  Expected: hear both the Spotify track and (via the system mixdown of
  whatever is playing back through the speakers, not direct mic) the user
  voice's monitored output. The transcript run produces a single speaker
  stream from output.m4a — diarization may split Spotify vocals from
  meeting voices.

- [ ] **Step 4: Smoke — multi-display, exclude self**

  Only if you have ≥2 displays connected.

  1. In the picker, pick the secondary display.
  2. Press Start Recording.
  3. While recording, drag the Meeting menu-bar popover / Library window
     onto the secondary display.
  4. Stop with ⌘. and open `video.mov`.

  Expected: Meeting's own UI does NOT appear in the recorded video
  (`excludingApplications: [self]` works).

- [ ] **Step 5: Smoke — display source, integrations skipped**

  Same as Step 3, but watch the menu-bar icon during the display
  recording.

  Expected:
  - No mic-gate icon appears in the menu bar (MicGate was skipped).
  - `~/Documents/Meetings/<latest>/` does NOT contain `mic_gate.json`
    or `meet_participants.json`.

- [ ] **Step 6: Smoke — Stop & Transcribe both paths**

  Run a 15-second recording for each source type and trigger Stop &
  Transcribe (⇧⌘.) from the popover.

  Expected: `transcript.md` is produced in each folder. The Library lists
  both new meetings. Transcript Viewer opens for both.

- [ ] **Step 7: Commit any post-smoke fixes; otherwise mark complete**

If smoke uncovers issues, fix them, rerun the affected step, and commit.
If everything passes, no commit is needed for this task — just confirm
the implementation is done.

---

## Self-review checklist (run after writing the plan, not at execution time)

This section is for the plan author, not the executor. Already done:

- [x] Spec coverage: every section of `2026-05-15-fullscreen-recording-design.md` has a task — Source abstraction (Task 1), ProcessAudioTap (Task 2), ScreenCaptureCoordinator (Task 3), RecordingSession orchestration & toggles (Task 4), Picker model (Task 5), Picker UI (Task 6), Popover migration (Task 7), Testing (Task 8 + unit tests in Tasks 1/5).
- [x] No placeholders ("TBD", "TODO", "etc"), every step contains complete code.
- [x] Type consistency: `CaptureSource` / `PickerSource` / `ProcessAudioTap.TapTarget` names are stable across tasks.
- [x] Single execution-time deviation: spec mentions hiding `tapProcessCount` chip when 0; no consumer of that property exists in the UI today, so the plan keeps the invariant in `ProcessAudioTap` (`processCount = 0` for `.system`) but adds no UI changes for a non-existent chip. Spec section "Header rendering" line about the chip is therefore future-proofing only.
