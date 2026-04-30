import Foundation
import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import CoreAudio
import EventKit

enum Permission: String, CaseIterable, Identifiable, Sendable {
    case screenRecording
    case microphone
    case audioCapture
    /// Optional — needed only for `MicGate` to read Google Meet's mic-button
    /// state via the AX API and skip transcribing muted intervals. Without
    /// it the app records and transcribes normally; only the mute-skip
    /// optimisation goes silent.
    case accessibility
    /// Optional — calendar integration is a quality-of-life feature, not
    /// a recording requirement. Shown in the permission gate but excluded
    /// from `PermissionStatus.allGranted` so it never blocks recording.
    case calendar

    var id: String { rawValue }

    var title: String {
        switch self {
        case .screenRecording: "Screen Recording"
        case .microphone: "Microphone"
        case .audioCapture: "Audio Capture (Core Audio Tap)"
        case .accessibility: "Accessibility (optional)"
        case .calendar: "Calendar (optional)"
        }
    }

    var detail: String {
        switch self {
        case .screenRecording: "บันทึกหน้าต่างที่เลือก (ScreenCaptureKit)"
        case .microphone: "บันทึกเสียงไมค์ของคุณ"
        case .audioCapture: "ดักเสียงเฉพาะของแอพประชุม (Zoom/Meet)"
        case .accessibility: "อ่านสถานะปุ่ม mic ของ Google Meet เพื่อข้าม transcribe ตอนปิดไมค์ — ไม่บังคับ"
        case .calendar: "ใช้ชื่อนัดและรายชื่อผู้เข้าร่วมจาก Calendar.app — ไม่บังคับ"
        }
    }

    /// Whether recording is allowed to start without this permission.
    /// Calendar and Accessibility are optional today.
    var isRequired: Bool {
        switch self {
        case .calendar, .accessibility: false
        default: true
        }
    }
}

struct PermissionStatus: Equatable, Sendable {
    var screenRecording: Bool = false
    var microphone: Bool = false
    var audioCapture: Bool = false
    var accessibility: Bool = false
    var calendar: Bool = false

    /// True when every *required* permission is granted. Calendar and
    /// Accessibility are optional and intentionally not part of this gate.
    var allGranted: Bool {
        screenRecording && microphone && audioCapture
    }

    func granted(for permission: Permission) -> Bool {
        switch permission {
        case .screenRecording: screenRecording
        case .microphone: microphone
        case .audioCapture: audioCapture
        case .accessibility: accessibility
        case .calendar: calendar
        }
    }
}

enum PermissionManager {
    private static let audioCaptureGrantedKey = "dev.fluke.meeting.audioCaptureGranted"

    static func currentStatus() async -> PermissionStatus {
        await Task.detached(priority: .userInitiated) {
            PermissionStatus(
                screenRecording: CGPreflightScreenCaptureAccess(),
                microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                audioCapture: UserDefaults.standard.bool(forKey: audioCaptureGrantedKey) && probeAudioCapture(),
                accessibility: AXIsProcessTrusted(),
                calendar: calendarAuthorized()
            )
        }.value
    }

    static func request(_ permission: Permission) async {
        switch permission {
        case .screenRecording:
            _ = await Task.detached(priority: .userInitiated) {
                CGRequestScreenCaptureAccess()
            }.value

        case .microphone:
            _ = await AVCaptureDevice.requestAccess(for: .audio)

        case .audioCapture:
            // Triggers TCC prompt on first call. Cache success so subsequent
            // status checks don't have to spin up a tap on every refresh.
            let granted = await Task.detached(priority: .userInitiated) {
                probeAudioCapture()
            }.value
            UserDefaults.standard.set(granted, forKey: audioCaptureGrantedKey)

        case .accessibility:
            // AXIsProcessTrustedWithOptions(prompt=true) shows the system
            // "open System Settings" dialog if the app isn't already trusted;
            // it never returns true on the same call (the user has to flip
            // the toggle in Settings and we re-check via Refresh). The call
            // returns synchronously — the Task.detached just keeps the
            // call off the main thread as a precaution.
            //
            // `kAXTrustedCheckOptionPrompt` is a global CFString constant
            // imported as `var` so Swift 6 strict concurrency rejects it as
            // shared mutable state; hard-coding the literal key dodges the
            // diagnostic without any behavioural change.
            await Task.detached(priority: .userInitiated) {
                let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
            }.value

        case .calendar:
            await requestCalendar()
        }
    }

    private static func calendarAuthorized() -> Bool {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .authorized, .fullAccess: true
        default: false
        }
    }

    private static func requestCalendar() async {
        // On macOS 14+, EventKit's permission dialog needs a "regular"
        // app context to anchor itself. Pure menu-bar apps
        // (.accessory activation policy) sometimes get a silent
        // `granted=false` returned from `requestFullAccessToEvents`
        // without TCC ever showing a dialog — the request is rejected
        // before it reaches the user. The reliable workaround is to
        // temporarily flip to `.regular`, activate the app, request
        // access, and then drop back. The app briefly appears in the
        // Dock during this window; we accept that as the cost of
        // making the prompt actually appear.
        let priorPolicy = await MainActor.run { NSApp.activationPolicy() }
        await MainActor.run {
            if priorPolicy != .regular {
                NSApp.setActivationPolicy(.regular)
            }
            NSApp.activate(ignoringOtherApps: true)
        }

        let store = EKEventStore()

        // Warm-up call: touching `calendars(for:)` before the request
        // nudges EventKit / tccd into recognising the app, which
        // matters in the edge case where the bundle hasn't been
        // associated with a TCC entry yet.
        _ = store.calendars(for: .event)

        let before = EKEventStore.authorizationStatus(for: .event).rawValue
        NSLog("[Meeting/Permission] calendar request — status before=%d", before)
        if #available(macOS 14.0, *) {
            do {
                let granted = try await store.requestFullAccessToEvents()
                NSLog("[Meeting/Permission] calendar request — granted=%@",
                      granted ? "true" : "false")
            } catch {
                NSLog("[Meeting/Permission] calendar request — error: %@",
                      String(describing: error))
            }
        } else {
            let granted: Bool = await withCheckedContinuation { cont in
                store.requestAccess(to: .event) { ok, _ in cont.resume(returning: ok) }
            }
            NSLog("[Meeting/Permission] calendar request — legacy granted=%@",
                  granted ? "true" : "false")
        }
        let after = EKEventStore.authorizationStatus(for: .event).rawValue
        NSLog("[Meeting/Permission] calendar request — status after=%d", after)

        // Restore the menu-bar-only activation policy so the app stops
        // appearing in the Dock.
        await MainActor.run {
            if priorPolicy != .regular {
                NSApp.setActivationPolicy(priorPolicy)
            }
        }
    }

    private static func probeAudioCapture() -> Bool {
        // A global "tap nothing excluded" is a valid tap that Core Audio accepts;
        // an empty stereoMixdownOfProcesses array fails with -10877 invalidElement
        // and never triggers the TCC prompt.
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.muteBehavior = .unmuted
        var tapID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &tapID)
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            _ = AudioHardwareDestroyProcessTap(tapID)
        }
        if status != noErr {
            NSLog("[Meeting/Permission] audio-capture probe failed: OSStatus %d", status)
        }
        return status == noErr
    }
}
