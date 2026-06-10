import AVFoundation
import CoreMedia
import Foundation

/// Bundles a meeting's separate recordings into one shareable `.mp4`:
/// the (silent) screen recording, both audio captures as two selectable
/// tracks (meeting output first, mic second), and the transcript as a
/// toggleable soft subtitle track (tx3g).
///
/// Video (HEVC) and audio (AAC) are copied through without re-encoding —
/// this is a remux, so even a multi-GB recording exports in seconds. The
/// audio files are already silence-padded to wall-clock time to match
/// `video.mov` (see ProcessAudioTap), so every track is inserted at t=0
/// with no offset compensation.
actor MeetingVideoExporter {
    enum ExportError: LocalizedError {
        case noVideo
        case unreadable(String)
        case writerFailed(Error)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .noVideo: return "This meeting has no video recording to export."
            case .unreadable(let s): return "Couldn't read \(s)."
            case .writerFailed(let e): return "Export failed: \(e.localizedDescription)"
            case .cancelled: return "Export cancelled."
            }
        }
    }

    /// Export `meetingFolder` to `destination` (a `.mp4` URL). `names` maps
    /// speaker IDs to display labels for the subtitle prefix; pass the
    /// library-resolved names, or leave empty to fall back to the transcript's.
    func export(
        meetingFolder: URL,
        names: [SpeakerID: String] = [:],
        to destination: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let fm = FileManager.default
        let videoURL = meetingFolder.appendingPathComponent("video.mov")
        guard fm.fileExists(atPath: videoURL.path) else { throw ExportError.noVideo }
        try? fm.removeItem(at: destination)

        // Subtitles are best-effort: a missing/short transcript just means no
        // subtitle track, never a failed export.
        var cues: [TimedTextCue] = []
        var transcriptDuration: TimeInterval = 0
        if let t = try? MergedTranscript.read(from: meetingFolder) {
            cues = TimedText.cues(from: t, names: names)
            transcriptDuration = t.duration
        }

        let micURL = meetingFolder.appendingPathComponent("mic.m4a")
        let outURL = meetingFolder.appendingPathComponent("output.m4a")

        let pipeline = try await ExportPipeline.make(
            video: videoURL,
            outputAudio: fm.fileExists(atPath: outURL.path) ? outURL : nil,
            micAudio: fm.fileExists(atPath: micURL.path) ? micURL : nil,
            cues: cues,
            transcriptDuration: transcriptDuration,
            destination: destination
        )

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                pipeline.run(progress: progress) { cont.resume(with: $0) }
            }
        } onCancel: {
            pipeline.cancel()
        }
    }
}

// MARK: - Subtitle cue model + tx3g encoding (pure, unit-tested)

struct TimedTextCue: Equatable, Sendable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
}

enum TimedText {
    /// One cue per transcript segment, prefixed with the speaker's display
    /// name (`"Me: …"`). Segments are sorted by start time and overlaps are
    /// clamped — tx3g shows one cue at a time, so a cue can't start before the
    /// previous one ends. Zero/negative-duration segments are dropped.
    static func cues(from transcript: MergedTranscript, names: [SpeakerID: String]) -> [TimedTextCue] {
        let resolved = names.isEmpty
            ? Dictionary(transcript.speakers.map { ($0.id, $0.displayName) }, uniquingKeysWith: { a, _ in a })
            : names
        var cues: [TimedTextCue] = []
        var lastEnd: TimeInterval = 0
        for seg in transcript.segments.sorted(by: { $0.start < $1.start }) {
            let label = resolved[seg.speaker] ?? seg.speaker.rawValue
            let start = max(seg.start, lastEnd)
            guard seg.end > start else { continue }
            cues.append(TimedTextCue(start: start, end: seg.end, text: "\(label): \(seg.text)"))
            lastEnd = seg.end
        }
        return cues
    }

    /// tx3g sample payload: a big-endian `uint16` text length followed by the
    /// UTF-8 bytes. An empty string yields the 2-byte gap sample (`00 00`).
    static func sampleData(_ text: String) -> Data {
        let bytes = Array(text.utf8.prefix(Int(UInt16.max)))
        var data = Data()
        var len = UInt16(bytes.count).bigEndian
        withUnsafeBytes(of: &len) { data.append(contentsOf: $0) }
        data.append(contentsOf: bytes)
        return data
    }
}

/// Builds the tx3g `CMFormatDescription` for an mp4 subtitle track. The
/// structure is a full ISO/QuickTime sample-description entry in big-endian
/// byte order, handed to the CoreMedia bridge. Verified against AVAssetWriter
/// + AVAsset round-trip. Returns nil only if CoreMedia rejects the bytes.
enum Tx3g {
    static func makeFormatDescription() -> CMFormatDescription? {
        var body = Data()
        func u8(_ v: UInt8) { body.append(v) }
        func u16(_ v: UInt16) { var b = v.bigEndian; withUnsafeBytes(of: &b) { body.append(contentsOf: $0) } }
        func u32(_ v: UInt32) { var b = v.bigEndian; withUnsafeBytes(of: &b) { body.append(contentsOf: $0) } }

        u32(0)                                   // displayFlags
        u8(1)                                    // horizontal justification (center)
        u8(0xFF)                                 // vertical justification (-1 = bottom)
        u8(0); u8(0); u8(0); u8(0xFF)            // background color RGBA
        u16(0); u16(0); u16(0); u16(0)           // default text box: top,left,bottom,right
        u16(0); u16(0)                           // style: startChar, endChar
        u16(1)                                   // font ID
        u8(0)                                    // face style flags
        u8(18)                                   // font size
        u8(0xFF); u8(0xFF); u8(0xFF); u8(0xFF)   // text color RGBA

        // 'ftab' font table box
        let fontName = Array("Sans-Serif".utf8)
        var be = UInt32(8 + 2 + 2 + 1 + fontName.count).bigEndian
        withUnsafeBytes(of: &be) { body.append(contentsOf: $0) }
        body.append(contentsOf: Array("ftab".utf8))
        u16(1)                                   // entry count
        u16(1)                                   // font ID
        u8(UInt8(fontName.count))
        body.append(contentsOf: fontName)

        // Prepend the sample-description header: size, 'tx3g', 6 reserved, dataRefIndex.
        var desc = Data()
        var totalBE = UInt32(16 + body.count).bigEndian
        withUnsafeBytes(of: &totalBE) { desc.append(contentsOf: $0) }
        desc.append(contentsOf: Array("tx3g".utf8))
        desc.append(contentsOf: [0, 0, 0, 0, 0, 0])
        var dri = UInt16(1).bigEndian
        withUnsafeBytes(of: &dri) { desc.append(contentsOf: $0) }
        desc.append(body)

        var fd: CMFormatDescription?
        let status = desc.withUnsafeBytes { raw -> OSStatus in
            CMTextFormatDescriptionCreateFromBigEndianTextDescriptionData(
                allocator: kCFAllocatorDefault,
                bigEndianTextDescriptionData: raw.bindMemory(to: UInt8.self).baseAddress!,
                size: raw.count,
                flavor: nil,
                mediaType: kCMMediaType_Subtitle,
                formatDescriptionOut: &fd)
        }
        return status == noErr ? fd : nil
    }

    /// A tx3g `CMSampleBuffer` for one cue.
    static func sampleBuffer(text: String, start: CMTime, duration: CMTime, format: CMFormatDescription) -> CMSampleBuffer? {
        let payload = TimedText.sampleData(text)
        let n = payload.count
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: n,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: n, flags: 0, blockBufferOut: &block) == kCMBlockBufferNoErr,
            let block else { return nil }
        let copied = payload.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: n)
        }
        guard copied == kCMBlockBufferNoErr else { return nil }

        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: start, decodeTimeStamp: .invalid)
        var size = n
        let status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
        return status == noErr ? sample : nil
    }
}

// MARK: - Remux pipeline

/// Owns the AVAssetReaders/Writer and pumps samples on a serial queue. Marked
/// `@unchecked Sendable` because the AVFoundation types aren't Sendable but are
/// only ever touched from `queue`, matching the project's audio-box pattern.
private final class ExportPipeline: @unchecked Sendable {
    private struct Leg {
        let reader: AVAssetReader
        let output: AVAssetReaderTrackOutput
        let input: AVAssetWriterInput
    }
    private struct SubtitleSample {
        let text: String
        let start: CMTime
        let duration: CMTime
    }

    private let writer: AVAssetWriter
    private let destination: URL
    private let legs: [Leg]
    private let progressLeg: Leg?          // the video leg, used to report progress
    private let totalDuration: Double
    private let subtitleInput: AVAssetWriterInput?
    private let subtitleFormat: CMFormatDescription?
    private var subtitleSamples: [SubtitleSample]
    private var subtitleIndex = 0

    private let queue = DispatchQueue(label: "dev.fluke.meeting.export")
    private var pending = 0
    private var finished = false
    private var cancelled = false
    private var completion: ((Result<Void, Error>) -> Void)?
    private var progress: (@Sendable (Double) -> Void)?

    private init(writer: AVAssetWriter, destination: URL, legs: [Leg], progressLeg: Leg?,
                 totalDuration: Double, subtitleInput: AVAssetWriterInput?,
                 subtitleFormat: CMFormatDescription?, subtitleSamples: [SubtitleSample]) {
        self.writer = writer
        self.destination = destination
        self.legs = legs
        self.progressLeg = progressLeg
        self.totalDuration = totalDuration
        self.subtitleInput = subtitleInput
        self.subtitleFormat = subtitleFormat
        self.subtitleSamples = subtitleSamples
    }

    static func make(
        video: URL, outputAudio: URL?, micAudio: URL?,
        cues: [TimedTextCue], transcriptDuration: Double, destination: URL
    ) async throws -> ExportPipeline {
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true

        func makeLeg(_ url: URL, mediaType: AVMediaType, label: String) async throws -> Leg {
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: mediaType).first else {
                throw MeetingVideoExporter.ExportError.unreadable(label)
            }
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw MeetingVideoExporter.ExportError.unreadable(label) }
            reader.add(output)
            let fmt = try await track.load(.formatDescriptions).first
            let input = AVAssetWriterInput(mediaType: mediaType, outputSettings: nil, sourceFormatHint: fmt)
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else { throw MeetingVideoExporter.ExportError.unreadable(label) }
            writer.add(input)
            return Leg(reader: reader, output: output, input: input)
        }

        // Track order: video, then meeting output audio (default), then mic.
        let videoLeg = try await makeLeg(video, mediaType: .video, label: "video.mov")
        var legs = [videoLeg]
        if let outputAudio { legs.append(try await makeLeg(outputAudio, mediaType: .audio, label: "output.m4a")) }
        if let micAudio { legs.append(try await makeLeg(micAudio, mediaType: .audio, label: "mic.m4a")) }

        // Duration for progress: prefer the video track's, fall back to transcript.
        let videoDuration = (try? await AVURLAsset(url: video).load(.duration).seconds) ?? 0
        let duration = max(videoDuration, transcriptDuration, 0.001)

        // Subtitle track (best-effort).
        var subtitleInput: AVAssetWriterInput?
        var subtitleFormat: CMFormatDescription?
        var subtitleSamples: [SubtitleSample] = []
        if !cues.isEmpty, let format = Tx3g.makeFormatDescription() {
            let input = AVAssetWriterInput(mediaType: .subtitle, outputSettings: nil, sourceFormatHint: format)
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) {
                writer.add(input)
                subtitleInput = input
                subtitleFormat = format
                subtitleSamples = Self.buildSubtitleSamples(cues: cues)
            }
        }

        return ExportPipeline(
            writer: writer, destination: destination, legs: legs, progressLeg: videoLeg,
            totalDuration: duration, subtitleInput: subtitleInput,
            subtitleFormat: subtitleFormat, subtitleSamples: subtitleSamples)
    }

    /// Cues plus empty gap-filler samples so the subtitle track is contiguous.
    private static func buildSubtitleSamples(cues: [TimedTextCue]) -> [SubtitleSample] {
        func t(_ s: Double) -> CMTime { CMTime(seconds: max(0, s), preferredTimescale: 1000) }
        var samples: [SubtitleSample] = []
        var cursor = 0.0
        for cue in cues {
            if cue.start > cursor + 0.001 {
                samples.append(SubtitleSample(text: "", start: t(cursor), duration: t(cue.start - cursor)))
            }
            samples.append(SubtitleSample(text: cue.text, start: t(cue.start), duration: t(cue.end - cue.start)))
            cursor = cue.end
        }
        return samples
    }

    func cancel() {
        queue.async { [weak self] in self?.finish(.failure(MeetingVideoExporter.ExportError.cancelled)) }
    }

    func run(progress: @escaping @Sendable (Double) -> Void, completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async { [self] in
            self.completion = completion
            self.progress = progress

            for leg in legs where !leg.reader.startReading() {
                finish(.failure(MeetingVideoExporter.ExportError.writerFailed(
                    leg.reader.error ?? MeetingVideoExporter.ExportError.unreadable("reader"))))
                return
            }
            guard writer.startWriting() else {
                finish(.failure(MeetingVideoExporter.ExportError.writerFailed(
                    writer.error ?? MeetingVideoExporter.ExportError.unreadable("writer"))))
                return
            }
            writer.startSession(atSourceTime: .zero)

            pending = legs.count + (subtitleInput != nil ? 1 : 0)
            for leg in legs { pumpLeg(leg) }
            if let subtitleInput { pumpSubtitles(subtitleInput) }
        }
    }

    private func pumpLeg(_ leg: Leg) {
        leg.input.requestMediaDataWhenReady(on: queue) { [self] in
            while leg.input.isReadyForMoreMediaData {
                if cancelled { return }
                guard let sample = leg.output.copyNextSampleBuffer() else {
                    leg.input.markAsFinished()
                    legDone()
                    return
                }
                if leg.reader === progressLeg?.reader, let p = progress {
                    let secs = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                    if secs.isFinite { p(min(max(secs / totalDuration, 0), 1)) }
                }
                if !leg.input.append(sample) {
                    finish(.failure(MeetingVideoExporter.ExportError.writerFailed(
                        writer.error ?? MeetingVideoExporter.ExportError.unreadable("append"))))
                    return
                }
            }
        }
    }

    private func pumpSubtitles(_ input: AVAssetWriterInput) {
        input.requestMediaDataWhenReady(on: queue) { [self] in
            while input.isReadyForMoreMediaData {
                if cancelled { return }
                guard subtitleIndex < subtitleSamples.count, let format = subtitleFormat else {
                    input.markAsFinished()
                    legDone()
                    return
                }
                let s = subtitleSamples[subtitleIndex]
                subtitleIndex += 1
                guard let buffer = Tx3g.sampleBuffer(text: s.text, start: s.start, duration: s.duration, format: format),
                      input.append(buffer) else {
                    // Subtitles are best-effort: stop the track, keep the export.
                    input.markAsFinished()
                    legDone()
                    return
                }
            }
        }
    }

    private func legDone() {
        pending -= 1
        guard pending == 0, !finished, !cancelled else { return }
        writer.finishWriting { [self] in
            queue.async { [self] in
                if writer.status == .completed {
                    finish(.success(()))
                } else {
                    finish(.failure(MeetingVideoExporter.ExportError.writerFailed(
                        writer.error ?? MeetingVideoExporter.ExportError.unreadable("finish"))))
                }
            }
        }
    }

    /// Resolve exactly once; on failure/cancel tear down and delete the partial file.
    private func finish(_ result: Result<Void, Error>) {
        guard !finished else { return }
        finished = true
        if case .failure = result {
            cancelled = true
            if writer.status == .writing { writer.cancelWriting() }
            for leg in legs { leg.reader.cancelReading() }
            try? FileManager.default.removeItem(at: destination)
        }
        let done = completion
        completion = nil
        progress = nil
        done?(result)
    }
}
