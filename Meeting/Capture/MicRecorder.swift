import Foundation
import AVFoundation
import CoreAudio

// Intentionally NOT @MainActor: AVAudioEngine calls the install-tap block on
// its render thread. With @MainActor isolation, the inherited closure would
// trip Swift 6's runtime queue assertion the moment audio starts flowing.
final class MicRecorder: @unchecked Sendable {
    private var engine: AVAudioEngine?
    private var file: AVAudioFile?
    /// Human-readable name of the input device, if AVCaptureDevice can
    /// resolve one — surfaced as "Built-in Microphone" in the recording
    /// window's mic channel sublabel.
    private(set) var deviceName: String?

    /// Push level samples into the caller-provided ring buffer so the UI
    /// can render a live waveform without owning the recorder.
    ///
    /// `deviceUID` pins the engine to a specific audio device (matched by
    /// its stable `kAudioDevicePropertyDeviceUID`). `nil` falls back to the
    /// system default — same behavior we shipped before Settings landed.
    func start(url: URL, deviceUID: String? = nil, rmsBuffer: RMSRingBuffer? = nil) throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode

        // Pin a specific input device when the user has chosen one in
        // Settings → Recording. Must happen BEFORE the input format is
        // queried and BEFORE the tap is installed — switching the device
        // resets the audio unit's negotiated format. Failure to pin is
        // surfaced via deviceName below; we don't throw because falling
        // back to the system default is preferable to refusing to record.
        let resolvedDevice: AudioObjectID? = {
            guard let uid = deviceUID, !uid.isEmpty else { return nil }
            guard let device = AudioInputDevices.find(uid: uid) else { return nil }
            if let unit = input.audioUnit {
                var deviceID = device.id
                let status = AudioUnitSetProperty(
                    unit,
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global,
                    0,
                    &deviceID,
                    UInt32(MemoryLayout<AudioObjectID>.size)
                )
                if status != noErr {
                    NSLog("[Meeting/Mic] failed to pin device %@ (status=%d) — using system default",
                          uid, status)
                    return nil
                }
            }
            return device.id
        }()

        // Switch the input node to the system's voice-processing audio unit
        // (kAudioUnitSubType_VoiceProcessingIO). This delivers Apple's built-in
        // automatic gain control + spectral noise suppression on the captured
        // mic stream — meaning a quiet mic gets boosted to a usable level
        // before AAC encoding (no more -44 LUFS recordings) and steady-state
        // background noise is attenuated. Echo cancellation is best-effort:
        // it works against audio our engine renders, which we don't, so the
        // post-process AEC against output.m4a still does the heavy lifting.
        // Side-effects: the input format flips to 16/24 kHz mono after this
        // call, which is why we re-query the format on the next line.
        do {
            try input.setVoiceProcessingEnabled(true)
        } catch {
            NSLog("[Meeting/Mic] setVoiceProcessingEnabled failed: %@ — falling back to raw input",
                  String(describing: error))
        }

        let inputFormat = input.outputFormat(forBus: 0)

        // Resolve the device's display name for UI sublabels. Prefer the
        // pinned-device's name when we set one; otherwise ask AVCapture.
        if let pinnedID = resolvedDevice,
           let device = AudioInputDevices.enumerate().first(where: { $0.id == pinnedID }) {
            self.deviceName = device.name
        } else {
            self.deviceName = AVCaptureDevice.default(for: .audio)?.localizedName
        }

        let fileSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: inputFormat.sampleRate,
            AVNumberOfChannelsKey: inputFormat.channelCount,
            AVEncoderBitRateKey: 64_000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]

        // commonFormat = pcmFormatFloat32 matches the input tap buffer's
        // format; AVAudioFile encodes to AAC on write. URL must end in .m4a
        // so the system picks the MPEG-4 container.
        let file = try AVAudioFile(
            forWriting: url,
            settings: fileSettings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        let box = AudioFileBox(file: file)
        let levels = rmsBuffer
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { @Sendable buffer, _ in
            do {
                try box.file.write(from: buffer)
            } catch {
                NSLog("[Meeting] mic write error: %@", String(describing: error))
            }
            if let levels {
                levels.push(RMSRingBuffer.computeNormalized(buffer: buffer))
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
        // Releases AVAudioFile, which finalizes the m4a (writes the moov
        // atom). If the process dies before this point, the file is unplayable.
        file = nil
    }
}

private final class AudioFileBox: @unchecked Sendable {
    let file: AVAudioFile
    init(file: AVAudioFile) { self.file = file }
}
