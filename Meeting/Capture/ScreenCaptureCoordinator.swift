import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia

@MainActor
final class ScreenCaptureCoordinator: NSObject {
    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private let recordingOutputDelegate = RecordingOutputLogger()
    private let streamDelegate = StreamErrorLogger()
    private let frameSink = FrameSink()
    private let frameQueue = DispatchQueue(label: "dev.fluke.meeting.frame-sink")

    func start(source: CaptureSource, videoURL: URL) async throws {
        let filter: SCContentFilter
        let captureSize: CGSize

        switch source {
        case .window(let window):
            filter = SCContentFilter(desktopIndependentWindow: window)
            captureSize = window.frame.size

        case .display(let display):
            // Exclude our own app from the captured surface so the
            // popover / future recording window does not appear in the
            // video. exceptingWindows:[] keeps every non-self window
            // visible on the display.
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
        // Capture at logical pixel size (not retina × scale). For meeting
        // playback the user reads transcripts, glances at the video for
        // context — sub-retina is fine and it cuts encoded bytes by ~4×.
        config.width = max(2, Int(captureSize.width))
        config.height = max(2, Int(captureSize.height))
        // 10 fps is enough for talking heads + slide changes; cuts another 3×.
        config.minimumFrameInterval = CMTime(value: 1, timescale: 10)
        config.queueDepth = 8
        config.capturesAudio = false       // system audio comes via Core Audio Tap (M3)
        config.captureMicrophone = false   // mic captured separately via MicRecorder
        config.showsCursor = true
        config.pixelFormat = kCVPixelFormatType_32BGRA

        let stream = SCStream(filter: filter, configuration: config, delegate: streamDelegate)

        let recConfig = SCRecordingOutputConfiguration()
        recConfig.outputURL = videoURL
        recConfig.outputFileType = .mov
        // HEVC for ~30-40% smaller files at the same perceived quality.
        recConfig.videoCodecType = .hevc

        let recOutput = SCRecordingOutput(configuration: recConfig, delegate: recordingOutputDelegate)
        try stream.addRecordingOutput(recOutput)

        // SCStream still emits frames into its delivery pipeline even when
        // SCRecordingOutput is the writer; without an SCStreamOutput the
        // pipeline floods the log with "stream output NOT found. Dropping frame".
        // A no-op stream output silences that without affecting recording.
        try stream.addStreamOutput(frameSink, type: .screen, sampleHandlerQueue: frameQueue)

        try await stream.startCapture()

        self.stream = stream
        self.recordingOutput = recOutput
    }

    func stop() async throws {
        guard let stream else { return }
        // stopCapture finalizes the SCRecordingOutput's file. Removing the
        // output before stopping can cut writes off mid-frame, so we don't.
        try await stream.stopCapture()
        self.stream = nil
        self.recordingOutput = nil
    }
}

private final class RecordingOutputLogger: NSObject, SCRecordingOutputDelegate, @unchecked Sendable {
    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) {
        NSLog("[Meeting] SCRecordingOutput error: %@", String(describing: error))
    }
}

private final class StreamErrorLogger: NSObject, SCStreamDelegate, @unchecked Sendable {
    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        NSLog("[Meeting] SCStream stopped with error: %@", String(describing: error))
    }
}

// SCRecordingOutput handles the actual file writing; this output exists only
// to drain the SCStream sample pipeline so it stops emitting "stream output
// NOT found" warnings.
private final class FrameSink: NSObject, SCStreamOutput, @unchecked Sendable {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // intentional no-op
    }
}
