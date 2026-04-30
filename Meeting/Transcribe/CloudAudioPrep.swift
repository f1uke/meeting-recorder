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

    /// 6 min — empirically the threshold past which LLM-based
    /// transcription starts losing fidelity on long audio. Below this,
    /// attention is tight enough that timestamps stay close to ground
    /// truth and content stays verbatim.
    static let defaultChunkDuration: TimeInterval = 360

    /// Decode → preprocess → chunk audio for upload to a cloud provider.
    /// Always loads the file into a 16k mono float array (needed anyway
    /// for the chunking step), applies any requested preprocessing, then
    /// slices into temp WAV chunks. Caller is responsible for deleting
    /// any chunk where `isTemp` is true.
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

        applyPreprocessing(to: &audio, options: options, logTag: logTag)

        let totalDuration = Double(audio.count) / Double(sampleRate)
        var chunks: [Chunk] = []
        var startOffset: TimeInterval = 0
        while startOffset < totalDuration {
            let endOffset = min(startOffset + chunkDuration, totalDuration)
            let startSample = Int(startOffset * Double(sampleRate))
            let endSample = min(audio.count, Int(endOffset * Double(sampleRate)))
            guard startSample < endSample else { break }
            let chunkSamples = Array(audio[startSample..<endSample])
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(tempPrefix)-c\(chunks.count)-\(UUID().uuidString).wav")
            try writeWAV(chunkSamples, sampleRate: sampleRate, to: url)
            chunks.append(Chunk(url: url, offset: startOffset, isTemp: true))
            startOffset = endOffset
        }
        if chunks.count > 1 {
            NSLog("[Meeting/Transcribe] %@ split %.1fs audio into %d chunks of <=%.0fs",
                  logTag, totalDuration, chunks.count, chunkDuration)
        }
        return chunks
    }

    /// Apply mic preprocessing (AEC / normalize / mute gate) in place on
    /// the float array. Mirrors LocalProvider's array-path logic so mic
    /// transcripts from any cloud provider see the same audio bytes —
    /// minus the Whisper-specific quirks. Output stream passes none of
    /// the flags so this is a no-op for it.
    static func applyPreprocessing(
        to audio: inout [Float],
        options: TranscriptionOptions,
        logTag: String
    ) {
        if let refURL = options.referenceAudioURL {
            let refPath = refURL.path(percentEncoded: false)
            if FileManager.default.fileExists(atPath: refPath) {
                if let reference = try? AudioProcessor.loadAudioAsFloatArray(
                    fromPath: refPath,
                    channelMode: .sumChannels(nil)
                ),
                   let shift = AudioPreprocessor.findReferenceShift(
                       mic: audio, reference: reference
                   ) {
                    let backup = audio
                    AudioPreprocessor.subtractEcho(
                        mic: &audio,
                        reference: reference,
                        referenceShift: shift
                    )
                    var postPeak: Float = 0
                    vDSP_maxmgv(audio, 1, &postPeak, vDSP_Length(audio.count))
                    if postPeak > 1.5 {
                        audio = backup
                        NSLog("[Meeting/Transcribe] %@ AEC reverted: post-peak=%.2f (NLMS diverged)",
                              logTag, postPeak)
                    } else {
                        NSLog("[Meeting/Transcribe] %@ AEC: ref=%.1fs shift=%dms post-peak=%.3f",
                              logTag,
                              Double(reference.count) / 16000,
                              shift * 1000 / 16000,
                              postPeak)
                    }
                } else {
                    NSLog("[Meeting/Transcribe] %@ AEC skipped: cross-correlation found no reliable shift", logTag)
                }
            } else {
                NSLog("[Meeting/Transcribe] %@ AEC skipped: reference missing at %@", logTag, refPath)
            }
        }

        if options.normalizeLoudness {
            let (preDB, postDB) = AudioPreprocessor.peakNormalize(&audio)
            NSLog("[Meeting/Transcribe] %@ normalize: %.1f dBFS → %.1f dBFS", logTag, preDB, postDB)
        }

        if let muted = options.mutedIntervals, !muted.isEmpty {
            let sampleRate: Double = 16000
            for interval in muted {
                let startSample = max(0, Int(interval.start * sampleRate))
                let endSample = min(audio.count, Int(interval.end * sampleRate))
                guard startSample < endSample else { continue }
                for i in startSample..<endSample { audio[i] = 0 }
            }
            NSLog("[Meeting/Transcribe] %@ mic gate: %d intervals", logTag, muted.count)
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
