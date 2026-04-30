import Foundation
import Accelerate
import WhisperKit

/// Shared decoding + preprocessing + chunking for cloud transcription
/// providers (Gemini, OpenAI). Centralized so both providers see byte-
/// identical audio after AEC / normalize / mute-gate, and so the
/// chunking strategy stays consistent across them.
///
/// LLM-based transcription drifts on long audio (attention dilutes →
/// timestamps wander, late content gets summarized or hallucinated).
/// Slicing at ~6-minute boundaries keeps each generate call within the
/// model's accurate window. Output stream skips preprocessing because
/// it's already clean.
enum CloudAudioPrep {
    /// One transcription-bound slice of the source audio. `offset` is
    /// added back to every segment timestamp so the merged transcript
    /// matches the original recording's wall clock.
    struct Chunk: Sendable {
        let url: URL
        let offset: TimeInterval
        let isTemp: Bool
    }

    /// One contiguous span that survived the mute-gate / minimum-duration
    /// filter. Closed-open: `[start, end)`. AEC + normalize run only on
    /// these ranges; everything outside gets zeroed before chunking so
    /// downstream transcription never sees muted noise or accidental
    /// mic-toggle blips.
    struct VoicedRange: Sendable {
        let start: TimeInterval
        let end: TimeInterval
        var duration: TimeInterval { end - start }
    }

    /// 6 min — historical default for cloud chunking. Each provider now
    /// passes its own value (Gemini = 60 s, OpenAI per-model 90 / 360 s)
    /// so this is only a fallback for callers that don't specify.
    static let defaultChunkDuration: TimeInterval = 360

    /// Voiced intervals shorter than this are dropped — typically users
    /// flicking the mute toggle by accident, occasional background coughs,
    /// or fence-post noise from gate-detection start/stop. 2 s is short
    /// enough to keep "okay ครับ" / "yes" acks while filtering the
    /// stray-flick case the user reported.
    static let minVoicedDuration: TimeInterval = 2.0

    /// Decode → voiced-aware preprocess → chunk audio for upload to a
    /// cloud provider. Always loads the file into a 16k mono float array
    /// (needed anyway for the chunking step). Caller is responsible for
    /// deleting any chunk where `isTemp` is true.
    ///
    /// Voiced-aware: when `options.mutedIntervals` is non-empty, AEC and
    /// normalize run only on voiced ranges (≥ `minVoicedDuration`), and
    /// chunks are aligned to those ranges so we never upload silence.
    /// When the gate isn't set (output stream), behaviour is the legacy
    /// full-array preprocess + fixed-duration chunks + silence skip.
    ///
    /// `tempPrefix` lets each provider's chunks land under a recognizable
    /// filename so they can be diagnosed in /tmp without confusion.
    static func prepareChunks(
        audioURL: URL,
        options: TranscriptionOptions,
        tempPrefix: String,
        chunkDuration: TimeInterval = defaultChunkDuration,
        providerName: String,
        logTag: String
    ) throws -> [Chunk] {
        let sampleRate = 16000
        let path = audioURL.path(percentEncoded: false)

        var audio: [Float]
        do {
            audio = try AudioProcessor.loadAudioAsFloatArray(
                fromPath: path,
                channelMode: .sumChannels(nil)
            )
        } catch {
            throw TranscriptionError.providerFailed(providerName, underlying: error)
        }

        let voiced = applyVoicedPreprocessing(
            to: &audio,
            sampleRate: sampleRate,
            options: options,
            logTag: logTag
        )

        let totalDuration = Double(audio.count) / Double(sampleRate)
        var chunks: [Chunk] = []
        var skippedSilent = 0
        // Slice each voiced range into <= chunkDuration sub-chunks so
        // every uploaded chunk maps back to the source via a single
        // `offset`. RMS check still runs as a backstop — if the user
        // hadn't muted but a long silent stretch is in the audio (e.g.
        // output stream during a break), we still want to skip it.
        for range in voiced {
            var subStart = range.start
            while subStart < range.end {
                let subEnd = min(subStart + chunkDuration, range.end)
                let startSample = Int(subStart * Double(sampleRate))
                let endSample = min(audio.count, Int(subEnd * Double(sampleRate)))
                guard startSample < endSample else { break }
                let chunkSamples = Array(audio[startSample..<endSample])
                var rms: Float = 0
                vDSP_rmsqv(chunkSamples, 1, &rms, vDSP_Length(chunkSamples.count))
                let rmsDB = rms > 0 ? 20 * log10f(rms) : -120
                // LLM-based transcription (Gemini, gpt-4o-*) has no
                // internal VAD, so a fully-silent chunk gets
                // "transcribed" as a hallucinated continuation of the
                // system prompt. Speech RMS sits around −20 to −30 dBFS;
                // quiet-room noise floor sits around −55 to −60. −50
                // separates the two without dropping real-but-quiet speech.
                if rmsDB < -50 {
                    skippedSilent += 1
                    subStart = subEnd
                    continue
                }
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("\(tempPrefix)-c\(chunks.count)-\(UUID().uuidString).wav")
                try writeWAV(chunkSamples, sampleRate: sampleRate, to: url)
                chunks.append(Chunk(url: url, offset: subStart, isTemp: true))
                subStart = subEnd
            }
        }
        if chunks.count > 1 || skippedSilent > 0 {
            NSLog("[Meeting/Transcribe] %@ %.1fs audio → %d chunks of <=%.0fs (skipped %d silent)",
                  logTag, totalDuration, chunks.count, chunkDuration, skippedSilent)
        }
        return chunks
    }

    /// Compute voiced intervals from total duration and muted intervals.
    /// Drops voiced ranges shorter than `minDuration` so accidental mic
    /// toggles don't survive into transcription. With no muted intervals,
    /// returns the whole duration as one range (pre-filter).
    static func voicedIntervals(
        totalDuration: TimeInterval,
        muted: [MutedInterval],
        minDuration: TimeInterval
    ) -> [VoicedRange] {
        guard totalDuration > 0 else { return [] }
        if muted.isEmpty {
            // No gate available — treat the whole stream as voiced.
            // Filtering still applies (a full file >= minDuration in
            // practice for any real recording).
            let whole = VoicedRange(start: 0, end: totalDuration)
            return whole.duration >= minDuration ? [whole] : []
        }
        let sortedMuted = muted.sorted { $0.start < $1.start }
        var voiced: [VoicedRange] = []
        var cursor: TimeInterval = 0
        for m in sortedMuted {
            let mStart = max(0, m.start)
            let mEnd = min(totalDuration, m.end)
            if mStart > cursor {
                voiced.append(VoicedRange(start: cursor, end: mStart))
            }
            cursor = max(cursor, mEnd)
        }
        if cursor < totalDuration {
            voiced.append(VoicedRange(start: cursor, end: totalDuration))
        }
        return voiced.filter { $0.duration >= minDuration }
    }

    /// Apply mic preprocessing (AEC + normalize) in place on voiced ranges
    /// only, and zero everything outside those ranges. Returns the kept
    /// voiced ranges so callers can build chunks aligned to them.
    ///
    /// Why voiced-aware: NLMS AEC adapts on every sample. During muted
    /// regions mic = 0 but reference ≠ 0 → weights drift toward making
    /// predicted echo = -reference (wrong direction), polluting the next
    /// voiced range. Running AEC per-range with fresh weights avoids that
    /// drift and saves CPU proportional to the muted fraction.
    ///
    /// Used by both LocalProvider's array path (mic stream) and the
    /// cloud `prepareChunks` so mic preprocessing is byte-identical
    /// across providers.
    @discardableResult
    static func applyVoicedPreprocessing(
        to audio: inout [Float],
        sampleRate: Int = 16000,
        options: TranscriptionOptions,
        logTag: String
    ) -> [VoicedRange] {
        let totalDuration = Double(audio.count) / Double(sampleRate)
        let voiced = voicedIntervals(
            totalDuration: totalDuration,
            muted: options.mutedIntervals ?? [],
            minDuration: minVoicedDuration
        )

        // Reference audio + global cross-correlation shift used by AEC.
        // Both are constant across voiced ranges (capture is sample-locked
        // throughout the recording), so resolve once.
        var reference: [Float]? = nil
        var refShift: Int? = nil
        if let refURL = options.referenceAudioURL {
            let refPath = refURL.path(percentEncoded: false)
            if FileManager.default.fileExists(atPath: refPath) {
                if let r = try? AudioProcessor.loadAudioAsFloatArray(
                    fromPath: refPath,
                    channelMode: .sumChannels(nil)
                ) {
                    reference = r
                    refShift = AudioPreprocessor.findReferenceShift(mic: audio, reference: r)
                    if refShift == nil {
                        NSLog("[Meeting/Transcribe] %@ AEC skipped: cross-correlation found no reliable shift", logTag)
                    }
                }
            } else {
                NSLog("[Meeting/Transcribe] %@ AEC skipped: reference missing at %@", logTag, refPath)
            }
        }

        for range in voiced {
            let startSample = max(0, Int(range.start * Double(sampleRate)))
            let endSample = min(audio.count, Int(range.end * Double(sampleRate)))
            guard startSample < endSample else { continue }
            var slice = Array(audio[startSample..<endSample])

            if let ref = reference, let shift = refShift {
                let backup = slice
                // The NLMS helper indexes mic by `i`, ref by `i + shift`.
                // Slice indices restart at 0, so add the slice's absolute
                // start sample to keep the reference window aligned.
                AudioPreprocessor.subtractEcho(
                    mic: &slice,
                    reference: ref,
                    referenceShift: startSample + shift
                )
                var postPeak: Float = 0
                vDSP_maxmgv(slice, 1, &postPeak, vDSP_Length(slice.count))
                if postPeak > 1.5 {
                    slice = backup
                    NSLog("[Meeting/Transcribe] %@ AEC reverted on range %.1f-%.1fs: post-peak=%.2f",
                          logTag, range.start, range.end, postPeak)
                }
            }

            if options.normalizeLoudness {
                _ = AudioPreprocessor.peakNormalize(&slice)
            }

            audio.replaceSubrange(startSample..<endSample, with: slice)
        }

        // Zero everything outside the kept voiced ranges. Folds the old
        // mute gate, the short-voiced-range drop, and any pre-recording
        // header noise into a single sweep.
        zeroOutsideRanges(
            audio: &audio,
            ranges: voiced,
            sampleRate: sampleRate
        )

        if options.mutedIntervals?.isEmpty == false {
            let totalVoiced = voiced.reduce(0) { $0 + $1.duration }
            // Count how many voiced spans existed before the min-duration
            // filter so the log explains what got dropped.
            let preFilter = voicedIntervals(
                totalDuration: totalDuration,
                muted: options.mutedIntervals ?? [],
                minDuration: 0
            )
            NSLog("[Meeting/Transcribe] %@ voiced ranges: %d kept (≥%.1fs), %d dropped short, %.1fs of %.1fs total",
                  logTag, voiced.count, minVoicedDuration,
                  preFilter.count - voiced.count, totalVoiced, totalDuration)
        }

        return voiced
    }

    /// Zero every sample that doesn't fall inside one of `ranges`. Mute
    /// gate + short-voiced-range drop in one pass.
    private static func zeroOutsideRanges(
        audio: inout [Float],
        ranges: [VoicedRange],
        sampleRate: Int
    ) {
        let total = audio.count
        guard !ranges.isEmpty else {
            for i in 0..<total { audio[i] = 0 }
            return
        }
        let sorted = ranges.sorted { $0.start < $1.start }
        var cursor = 0
        for r in sorted {
            let rs = max(0, Int(r.start * Double(sampleRate)))
            let re = min(total, Int(r.end * Double(sampleRate)))
            if rs > cursor {
                for i in cursor..<rs { audio[i] = 0 }
            }
            cursor = max(cursor, re)
        }
        if cursor < total {
            for i in cursor..<total { audio[i] = 0 }
        }
    }

    /// Write a 16-bit PCM mono WAV. Hand-rolled rather than going through
    /// AVAudioFile because we already hold the [Float] array — round-
    /// tripping through AVAudioPCMBuffer adds ceremony with no payoff.
    /// WAV is the simplest format every provider's transcription endpoint
    /// accepts.
    static func writeWAV(_ samples: [Float], sampleRate: Int, to url: URL) throws {
        let count = samples.count
        var pcm = [Int16](repeating: 0, count: count)
        for i in 0..<count {
            let clamped = max(-1.0, min(1.0, samples[i]))
            pcm[i] = Int16(clamped * 32767)
        }
        let dataBytes = count * 2
        var data = Data(capacity: 44 + dataBytes)

        func appendLE32(_ v: UInt32) {
            withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) }
        }
        func appendLE16(_ v: UInt16) {
            withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) }
        }

        // RIFF header
        data.append(contentsOf: Array("RIFF".utf8))
        appendLE32(UInt32(36 + dataBytes))
        data.append(contentsOf: Array("WAVE".utf8))
        // fmt chunk
        data.append(contentsOf: Array("fmt ".utf8))
        appendLE32(16)              // PCM chunk size
        appendLE16(1)               // PCM format
        appendLE16(1)               // mono
        appendLE32(UInt32(sampleRate))
        appendLE32(UInt32(sampleRate * 2)) // byte rate
        appendLE16(2)               // block align
        appendLE16(16)              // bits per sample
        // data chunk
        data.append(contentsOf: Array("data".utf8))
        appendLE32(UInt32(dataBytes))
        pcm.withUnsafeBytes { raw in
            data.append(contentsOf: raw)
        }

        try data.write(to: url, options: [.atomic])
    }
}
