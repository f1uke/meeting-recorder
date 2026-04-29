import Foundation
import AVFoundation

// Intentionally NOT @MainActor: AVAudioEngine calls the install-tap block on
// its render thread. With @MainActor isolation, the inherited closure would
// trip Swift 6's runtime queue assertion the moment audio starts flowing.
final class MicRecorder: @unchecked Sendable {
    private var engine: AVAudioEngine?
    private var file: AVAudioFile?

    func start(url: URL) throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)

        let fileSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: inputFormat.sampleRate,
            AVNumberOfChannelsKey: inputFormat.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]

        // commonFormat = pcmFormatFloat32 matches the input tap buffer's format,
        // so AVAudioFile converts to int16 PCM on disk for a valid WAV file.
        let file = try AVAudioFile(
            forWriting: url,
            settings: fileSettings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        let box = AudioFileBox(file: file)
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { @Sendable buffer, _ in
            do {
                try box.file.write(from: buffer)
            } catch {
                NSLog("[Meeting] mic write error: %@", String(describing: error))
            }
        }

        try engine.start()
        self.engine = engine
        self.file = file
    }

    func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        file = nil  // releases AVAudioFile so the WAV trailer flushes
    }
}

private final class AudioFileBox: @unchecked Sendable {
    let file: AVAudioFile
    init(file: AVAudioFile) { self.file = file }
}
