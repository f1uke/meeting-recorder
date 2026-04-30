import Foundation
import AudioToolbox
import AVFoundation
import CoreAudio

// Captures the audio output of a single process (e.g. Zoom, Meet, Safari)
// into an AAC m4a file by:
//   1. Translating the target PID to a Core Audio process object
//   2. Creating a stereo-mixdown CATap on that process
//   3. Wrapping the tap in a private aggregate device
//   4. Running an IOProc on a dispatch queue that writes incoming
//      AudioBufferLists to AVAudioFile via AVAudioPCMBuffer.bufferListNoCopy
//
// NOT @MainActor: the IOProc block runs on its own queue. With MainActor
// isolation it would trip the same _dispatch_assert_queue_fail trap as
// MicRecorder.installTap.
final class ProcessAudioTap: @unchecked Sendable {
    private var processTapID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var deviceProcID: AudioDeviceIOProcID?
    private var fileBox: AudioFileBox?
    private let queue = DispatchQueue(label: "dev.fluke.meeting.process-tap", qos: .userInitiated)
    /// Number of audio process objects this tap is bridging — typically 1
    /// for native apps and 2-4+ for Electron/Chromium apps with helpers.
    /// Surfaced in the recording window's source sublabel so the user can
    /// verify the multi-process tap is wired up correctly.
    private(set) var processCount: Int = 0

    func start(targetPID: pid_t, targetBundleID: String?, url: URL, rmsBuffer: RMSRingBuffer? = nil) throws {
        // Electron / Chromium apps (Discord, Slack, VSCode...) produce audio
        // in helper processes whose PID differs from the main window's PID.
        // We tap every audio process whose bundleID shares a prefix with the
        // main app, so the helper's audio is captured as well.
        let processObjectIDs = Self.collectAudioObjectIDs(
            mainPID: targetPID,
            bundleIDPrefix: targetBundleID
        )
        guard !processObjectIDs.isEmpty else {
            throw TapError.translatePID(targetPID, OSStatus(kAudioHardwareBadObjectError))
        }
        self.processCount = processObjectIDs.count
        NSLog("[Meeting/Tap] start pid=%d bundle=%@ → tapping %d audio object(s): %@",
              targetPID,
              targetBundleID ?? "(none)",
              processObjectIDs.count,
              processObjectIDs.map { String($0) }.joined(separator: ","))

        let tapDescription = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
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
            kAudioAggregateDeviceNameKey: "MeetingTap-\(targetPID)",
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

        // The tap reports its native rate (typically 48 kHz) but the
        // aggregate device's drift-compensated IOProc delivers samples at
        // the main sub-device's clock rate (e.g. 44.1 kHz on AirPods). If
        // we declare the file at the tap's native rate, the recorded data
        // is labelled with the wrong sample rate → playback is too fast
        // and duration is short by (1 - aggRate/tapRate). Re-derive the
        // delivery format from the aggregate's nominal rate.
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

        // On-disk format = AAC in MPEG-4 container (.m4a).
        // Processing format = whatever the aggregate delivers (typically non-interleaved float32).
        // AVAudioFile encodes buffer → AAC automatically on write.
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

    func stop() {
        if let procID = deviceProcID, aggregateDeviceID != AudioObjectID(kAudioObjectUnknown) {
            _ = AudioDeviceStop(aggregateDeviceID, procID)
            _ = AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
        }
        deviceProcID = nil

        if aggregateDeviceID != AudioObjectID(kAudioObjectUnknown) {
            _ = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        }

        if processTapID != AudioObjectID(kAudioObjectUnknown) {
            _ = AudioHardwareDestroyProcessTap(processTapID)
            processTapID = AudioObjectID(kAudioObjectUnknown)
        }

        // Drain any pending write blocks before closing the file so the
        // m4a's moov atom is flushed against a fully-written body. If the
        // process dies before fileBox is released, the file is unplayable.
        queue.sync {}
        fileBox = nil
    }

    deinit { stop() }

    // MARK: - Helpers

    private static func collectAudioObjectIDs(mainPID: pid_t, bundleIDPrefix: String?) -> [AudioObjectID] {
        var collected: Set<AudioObjectID> = []

        // Always include the directly-translated main PID if available.
        if let direct = try? translatePIDToProcessObject(pid: mainPID),
           direct != AudioObjectID(kAudioObjectUnknown) {
            collected.insert(direct)
        }

        // Scan the system audio process list for siblings whose bundleID
        // shares the prefix of the main app (Electron helpers, etc.).
        if let prefix = bundleIDPrefix, !prefix.isEmpty,
           let allProcs = try? readAllAudioProcessObjectIDs() {
            for procID in allProcs {
                let bundleID = readProcessBundleID(processObjectID: procID)
                if !bundleID.isEmpty, bundleID == prefix || bundleID.hasPrefix(prefix + ".") {
                    collected.insert(procID)
                    NSLog("[Meeting/Tap] discovered helper: audioObj=%u bundleID=%@", procID, bundleID)
                }
            }
        }

        return Array(collected)
    }

    private static func readAllAudioProcessObjectIDs() throws -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        var err = AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &dataSize)
        guard err == noErr else { throw TapError.processList(err) }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }
        var ids = [AudioObjectID](repeating: AudioObjectID(kAudioObjectUnknown), count: count)
        err = AudioObjectGetPropertyData(systemObject, &address, 0, nil, &dataSize, &ids)
        guard err == noErr else { throw TapError.processList(err) }
        return ids
    }

    private static func readProcessBundleID(processObjectID: AudioObjectID) -> String {
        let value: CFString = (try? readProperty(
            objectID: processObjectID,
            selector: kAudioProcessPropertyBundleID,
            defaultValue: "" as CFString
        )) ?? ("" as CFString)
        return value as String
    }

    private static func translatePIDToProcessObject(pid: pid_t) throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var inPID = pid
        var processObjectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let err = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<pid_t>.size),
            &inPID,
            &size,
            &processObjectID
        )
        guard err == noErr, processObjectID != AudioObjectID(kAudioObjectUnknown) else {
            throw TapError.translatePID(pid, err)
        }
        return processObjectID
    }

    private static func readTapStreamFormat(tapID: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let err = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format)
        guard err == noErr else { throw TapError.tapFormat(err) }
        return format
    }

    private static func readDefaultSystemOutputDevice() throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let err = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil,
            &size, &deviceID
        )
        guard err == noErr else { throw TapError.outputDevice(err) }
        return deviceID
    }

    private static func readDeviceNominalSampleRate(deviceID: AudioDeviceID) throws -> Float64 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        let err = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &rate)
        guard err == noErr else { throw TapError.deviceUID(err) }
        return rate
    }

    private static func readDeviceUID(deviceID: AudioDeviceID) throws -> String {
        let uid: CFString = try readProperty(
            objectID: deviceID,
            selector: kAudioDevicePropertyDeviceUID,
            defaultValue: "" as CFString
        )
        return uid as String
    }

    private static func readProperty<T>(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        defaultValue: T
    ) throws -> T {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = defaultValue
        var size = UInt32(MemoryLayout<T>.size)
        let err = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, ptr)
        }
        guard err == noErr else { throw TapError.deviceUID(err) }
        return value
    }
}

private final class AudioFileBox: @unchecked Sendable {
    let file: AVAudioFile
    let format: AVAudioFormat
    let rmsBuffer: RMSRingBuffer?
    private let bytesPerChannelFrame: Int
    private var loggedFirst = false
    private var totalFrames: UInt64 = 0

    // CATap stops delivering buffers when the source process is silent, so
    // without intervention the file's timeline collapses to "audible time
    // only" while video.mov uses wall-clock time — playback ends up with
    // audio racing ahead of video and transcript timestamps mis-aligned.
    // We anchor on the device sample clock from the first IOProc call and
    // pad each subsequent gap with silence so the file's frame count tracks
    // wall-clock seconds.
    private var firstSampleTime: Double?
    private var paddedFrames: UInt64 = 0
    private var silenceBuffer: AVAudioPCMBuffer?

    init(file: AVAudioFile, format: AVAudioFormat, rmsBuffer: RMSRingBuffer? = nil) {
        self.file = file
        self.format = format
        self.rmsBuffer = rmsBuffer
        // Non-interleaved: bufferList has N buffers, each with 1 channel
        //   → bytes per channel-frame = mBytesPerFrame (already per-channel for non-interleaved ASBD)
        // Interleaved: bufferList has 1 buffer with all channels packed
        //   → bytes per frame = mBytesPerFrame (covers all channels)
        let bpf = Int(format.streamDescription.pointee.mBytesPerFrame)
        if format.isInterleaved {
            self.bytesPerChannelFrame = bpf
        } else {
            // For non-interleaved float32 stereo: ASBD.mBytesPerFrame = 4 (per channel)
            self.bytesPerChannelFrame = bpf
        }
    }

    func handleInput(
        bufferList inputData: UnsafePointer<AudioBufferList>,
        inputTime: UnsafePointer<AudioTimeStamp>
    ) {
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        let firstBytes = abl.count > 0 ? abl[0].mDataByteSize : 0
        let frameCount: AVAudioFrameCount = (firstBytes > 0 && bytesPerChannelFrame > 0)
            ? AVAudioFrameCount(Int(firstBytes) / bytesPerChannelFrame)
            : 0

        let ts = inputTime.pointee
        if ts.mFlags.contains(.sampleTimeValid) {
            if firstSampleTime == nil {
                firstSampleTime = ts.mSampleTime
            }
            if let base = firstSampleTime {
                let elapsed = Int64(ts.mSampleTime - base)
                let gap = elapsed - Int64(totalFrames)
                if gap > 0 {
                    writeSilence(frames: gap)
                }
            }
        }

        guard frameCount > 0 else { return }

        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            if !loggedFirst {
                loggedFirst = true
                NSLog("[Meeting/Tap] AVAudioPCMBuffer alloc failed: format=%@ frames=%u", format, frameCount)
            }
            return
        }
        pcmBuffer.frameLength = frameCount

        let dst = UnsafeMutableAudioBufferListPointer(pcmBuffer.mutableAudioBufferList)
        for i in 0..<min(dst.count, abl.count) {
            let bytes = min(abl[i].mDataByteSize, dst[i].mDataByteSize)
            if let src = abl[i].mData, let dstPtr = dst[i].mData, bytes > 0 {
                memcpy(dstPtr, src, Int(bytes))
            }
        }

        if !loggedFirst {
            loggedFirst = true
            NSLog("[Meeting/Tap] first IOProc OK: bufs=%u frames=%u bytes/buf=%u",
                  abl.count, frameCount, firstBytes)
        }

        do {
            try file.write(from: pcmBuffer)
            totalFrames += UInt64(frameCount)
        } catch {
            NSLog("[Meeting/Tap] write error: %@", String(describing: error))
        }

        if let rmsBuffer {
            rmsBuffer.push(RMSRingBuffer.computeNormalized(buffer: pcmBuffer))
        }
    }

    private func writeSilence(frames: Int64) {
        if silenceBuffer == nil {
            let cap: AVAudioFrameCount = 4096
            guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: cap) else { return }
            buf.frameLength = cap
            let abl = UnsafeMutableAudioBufferListPointer(buf.mutableAudioBufferList)
            for i in 0..<abl.count {
                if let p = abl[i].mData {
                    memset(p, 0, Int(abl[i].mDataByteSize))
                }
            }
            silenceBuffer = buf
        }
        guard let buf = silenceBuffer else { return }
        let cap = Int64(buf.frameCapacity)
        var remaining = frames
        while remaining > 0 {
            let chunk = AVAudioFrameCount(min(cap, remaining))
            buf.frameLength = chunk
            do {
                try file.write(from: buf)
                totalFrames += UInt64(chunk)
                paddedFrames += UInt64(chunk)
            } catch {
                NSLog("[Meeting/Tap] silence write error: %@", String(describing: error))
                return
            }
            remaining -= Int64(chunk)
        }
    }

    deinit {
        NSLog("[Meeting/Tap] file closed: total=%llu frames (silence-padded=%llu)",
              totalFrames, paddedFrames)
    }
}

enum TapError: LocalizedError {
    case translatePID(pid_t, OSStatus)
    case create(OSStatus)
    case tapFormat(OSStatus)
    case outputDevice(OSStatus)
    case deviceUID(OSStatus)
    case aggregate(OSStatus)
    case ioProc(OSStatus)
    case start(OSStatus)
    case processList(OSStatus)
    case formatUnavailable

    var errorDescription: String? {
        switch self {
        case .translatePID(let pid, let s):
            "แอพที่เลือก (PID \(pid)) ยังไม่ได้ใช้เสียง — เปิดเสียงในแอพแล้วลองใหม่ (OSStatus \(s))"
        case .create(let s): "AudioHardwareCreateProcessTap ล้มเหลว (OSStatus \(s)) — ตรวจสิทธิ์ Audio Capture"
        case .tapFormat(let s): "อ่าน tap format ไม่ได้ (OSStatus \(s))"
        case .outputDevice(let s): "อ่าน default output device ไม่ได้ (OSStatus \(s))"
        case .deviceUID(let s): "อ่าน device UID ไม่ได้ (OSStatus \(s))"
        case .aggregate(let s): "AudioHardwareCreateAggregateDevice ล้มเหลว (OSStatus \(s))"
        case .ioProc(let s): "AudioDeviceCreateIOProcID ล้มเหลว (OSStatus \(s))"
        case .start(let s): "AudioDeviceStart ล้มเหลว (OSStatus \(s))"
        case .processList(let s): "อ่าน audio process list ไม่ได้ (OSStatus \(s))"
        case .formatUnavailable: "สร้าง AVAudioFormat จาก tap stream description ไม่ได้"
        }
    }
}
