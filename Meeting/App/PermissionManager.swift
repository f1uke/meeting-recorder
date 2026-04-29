import Foundation
import AVFoundation
import CoreGraphics
import CoreAudio

enum Permission: String, CaseIterable, Identifiable, Sendable {
    case screenRecording
    case microphone
    case audioCapture

    var id: String { rawValue }

    var title: String {
        switch self {
        case .screenRecording: "Screen Recording"
        case .microphone: "Microphone"
        case .audioCapture: "Audio Capture (Core Audio Tap)"
        }
    }

    var detail: String {
        switch self {
        case .screenRecording: "บันทึกหน้าต่างที่เลือก (ScreenCaptureKit)"
        case .microphone: "บันทึกเสียงไมค์ของคุณ"
        case .audioCapture: "ดักเสียงเฉพาะของแอพประชุม (Zoom/Meet)"
        }
    }
}

struct PermissionStatus: Equatable, Sendable {
    var screenRecording: Bool = false
    var microphone: Bool = false
    var audioCapture: Bool = false

    var allGranted: Bool {
        screenRecording && microphone && audioCapture
    }

    func granted(for permission: Permission) -> Bool {
        switch permission {
        case .screenRecording: screenRecording
        case .microphone: microphone
        case .audioCapture: audioCapture
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
                audioCapture: UserDefaults.standard.bool(forKey: audioCaptureGrantedKey) && probeAudioCapture()
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
