import Foundation
import WhisperKit
import SpeakerKit

// Local-first transcription provider. Loads Whisper + (optional) SpeakerKit
// CoreML models once and runs:
//   - mic.m4a   →  WhisperKit + options.knownSpeaker = "me"
//   - output.m4a →  WhisperKit + SpeakerKit (pyannote v4) → speaker_0/1/...
//
// WhisperKit is a non-final open class so the compiler refuses to mark it
// Sendable. Wrapping it in @unchecked Sendable boxes lets us cross actor
// boundaries safely; both kits are internally thread-safe.
private struct KitBox: @unchecked Sendable { let kit: WhisperKit }
private struct DiarizerBox: @unchecked Sendable { let kit: SpeakerKit }

actor LocalProvider: TranscriptionProvider {
    nonisolated let name: String
    private let modelVariant: String

    private var kitBox: KitBox?
    private var kitLoadTask: Task<KitBox, Error>?

    private var diarizerBox: DiarizerBox?
    private var diarizerLoadTask: Task<DiarizerBox, Error>?

    // Default to `large-v3` (not `_turbo`): turbo is ~4× faster but auto-language
    // detection on Thai content has been observed to misclassify as English,
    // causing the whole transcript to come out in English even when speech is
    // clearly Thai. large-v3 is more reliable for non-Latin language detection.
    init(modelVariant: String = "large-v3") {
        self.modelVariant = modelVariant
        self.name = "WhisperKit (\(modelVariant)) + SpeakerKit"
    }

    /// Drop the WhisperKit + SpeakerKit handles so ARC can release the
    /// CoreML buffers (Whisper large-v3 alone is ~3GB resident). Safe to
    /// call mid-flight: any in-progress transcribe holds its own strong
    /// ref to the box for the duration of the call.
    func unloadModels() {
        kitBox = nil
        diarizerBox = nil
    }

    func transcribe(
        audioURL: URL,
        options: TranscriptionOptions,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> TranscriptResult {
        guard FileManager.default.fileExists(atPath: audioURL.path(percentEncoded: false)) else {
            throw TranscriptionError.audioMissing(audioURL)
        }

        let path = audioURL.path(percentEncoded: false)
        let kit = try await loadKit()

        // When diarization is enabled, Whisper is roughly the first ~80% of
        // wall time on the output stream and SpeakerKit the last ~20%; on a
        // mic-only pass Whisper is the whole 100%.
        let whisperShare: Double = options.withDiarization ? 0.80 : 1.0

        // Always run Whisper for text + word timestamps.
        let whisperReporter: (@Sendable (Double) -> Void)?
        if let report = progress {
            whisperReporter = { (fraction: Double) in
                report(min(whisperShare, fraction * whisperShare))
            }
        } else {
            whisperReporter = nil
        }

        let chunks: [TranscriptionResult]
        let needsArrayPath = (options.mutedIntervals?.isEmpty == false)
            || options.referenceAudioURL != nil
            || options.normalizeLoudness
        if needsArrayPath {
            // Array path: load the file as a 16 kHz mono float, optionally
            // (1) cancel speaker echo using a reference audio stream,
            // (2) gate muted-mic ranges, and (3) peak-normalize, then feed
            // the resulting array to Whisper directly. The on-disk archive
            // is unchanged — preprocessing only affects what the model sees.
            var audio = try Self.loadAudioArray(path: path, providerName: name)

            if let refURL = options.referenceAudioURL {
                let refPath = refURL.path(percentEncoded: false)
                if FileManager.default.fileExists(atPath: refPath) {
                    let reference = try Self.loadAudioArray(path: refPath, providerName: name)
                    let shift = AudioPreprocessor.findReferenceShift(
                        mic: audio, reference: reference
                    )
                    AudioPreprocessor.subtractEcho(
                        mic: &audio,
                        reference: reference,
                        referenceShift: shift
                    )
                    NSLog("[Meeting/Transcribe] AEC: ref=%.1fs shift=%dms taps=1024",
                          Double(reference.count) / 16000,
                          shift * 1000 / 16000)
                } else {
                    NSLog("[Meeting/Transcribe] AEC skipped: reference missing at %@", refPath)
                }
            }

            if options.normalizeLoudness {
                let (preDB, postDB) = AudioPreprocessor.peakNormalize(&audio)
                NSLog("[Meeting/Transcribe] normalize: %.1f dBFS → %.1f dBFS", preDB, postDB)
            }

            if let muted = options.mutedIntervals, !muted.isEmpty {
                Self.applyGate(to: &audio, sampleRate: 16000, mutedIntervals: muted)
                NSLog("[Meeting/Transcribe] mic gate applied: %d intervals → %.1fs of %.1fs zeroed",
                      muted.count,
                      muted.reduce(0) { $0 + ($1.end - $1.start) },
                      Double(audio.count) / 16000)
            }

            chunks = try await Self.runTranscribeArray(
                box: kit,
                audioArray: audio,
                language: options.language,
                providerName: name,
                onProgress: whisperReporter
            )
        } else {
            chunks = try await Self.runTranscribe(
                box: kit,
                audioPath: path,
                language: options.language,
                providerName: name,
                onProgress: whisperReporter
            )
        }

        if options.withDiarization {
            let dia = try await loadDiarizer()
            let diarizeReporter: (@Sendable (Double) -> Void)?
            if let report = progress {
                diarizeReporter = { (fraction: Double) in
                    report(min(1.0, whisperShare + fraction * (1.0 - whisperShare)))
                }
            } else {
                diarizeReporter = nil
            }
            let labeledGroups = try await Self.runDiarize(
                box: dia,
                audioPath: path,
                whisperChunks: chunks,
                expectedSpeakerCount: options.expectedSpeakerCount,
                providerName: name,
                onProgress: diarizeReporter
            )
            progress?(1.0)
            return Self.mapDiarized(
                groups: labeledGroups,
                whisperChunks: chunks,
                options: options,
                providerName: name,
                modelVariant: modelVariant
            )
        }

        progress?(1.0)
        return Self.mapKnownSpeaker(
            chunks: chunks,
            options: options,
            providerName: name,
            modelVariant: modelVariant
        )
    }

    // MARK: - Single-flight model loads

    private func loadKit() async throws -> KitBox {
        if let box = kitBox { return box }
        if let existing = kitLoadTask { return try await existing.value }

        let variant = modelVariant
        let downloadBase = ModelStorage.downloadBase()
        let task = Task<KitBox, Error> {
            let config = WhisperKitConfig(
                model: variant,
                downloadBase: downloadBase,
                verbose: false,
                logLevel: .error
            )
            do {
                let kit = try await WhisperKit(config)
                return KitBox(kit: kit)
            } catch {
                throw TranscriptionError.modelLoadFailed("\(variant): \(error.localizedDescription)")
            }
        }
        kitLoadTask = task
        defer { kitLoadTask = nil }

        let box = try await task.value
        kitBox = box
        return box
    }

    private func loadDiarizer() async throws -> DiarizerBox {
        if let box = diarizerBox { return box }
        if let existing = diarizerLoadTask { return try await existing.value }

        let downloadBase = ModelStorage.downloadBase().path(percentEncoded: false)
        let task = Task<DiarizerBox, Error> {
            // PyannoteConfig (community-1) downloads on first use. Override
            // the download base so models land in our Application Support
            // folder rather than ~/Documents/huggingface.
            let config = PyannoteConfig()
            config.verbose = false
            config.modelDownloadConfig = ModelDownloadConfig(
                downloadBase: downloadBase,
                modelRepo: "argmaxinc/speakerkit-coreml"
            )
            do {
                let kit = try await SpeakerKit(config)
                return DiarizerBox(kit: kit)
            } catch {
                throw TranscriptionError.modelLoadFailed(
                    "SpeakerKit pyannote: \(error.localizedDescription)"
                )
            }
        }
        diarizerLoadTask = task
        defer { diarizerLoadTask = nil }

        let box = try await task.value
        diarizerBox = box
        return box
    }

    // MARK: - Nonisolated workers

    private static func runTranscribe(
        box: KitBox,
        audioPath: String,
        language: String?,
        providerName: String,
        onProgress: (@Sendable (Double) -> Void)?
    ) async throws -> [TranscriptionResult] {
        let decode = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: language,
            skipSpecialTokens: true,
            withoutTimestamps: false,
            wordTimestamps: true,
            chunkingStrategy: .vad
        )

        // Snapshot Foundation Progress baseline. WhisperKit's `progress`
        // monotonically grows across calls (`totalUnitCount = max(...)`)
        // because the same Progress object is shared — without a baseline
        // a second call would start at the previous fractionCompleted.
        let baseCompleted = box.kit.progress.completedUnitCount
        let baseTotal = box.kit.progress.totalUnitCount

        let pollerTask: Task<Void, Never>? = onProgress.map { report in
            Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                    let p = box.kit.progress
                    let completed = p.completedUnitCount - baseCompleted
                    let total = p.totalUnitCount - baseTotal
                    guard total > 0 else { continue }
                    let f = max(0.0, min(1.0, Double(completed) / Double(total)))
                    report(f)
                }
            }
        }
        defer { pollerTask?.cancel() }

        do {
            return try await box.kit.transcribe(audioPath: audioPath, decodeOptions: decode)
        } catch {
            throw TranscriptionError.providerFailed(providerName, underlying: error)
        }
    }

    /// Load the file as 16 kHz mono float array via WhisperKit's helper —
    /// shares the same resampling path Whisper would use internally so the
    /// gated array sees identical audio to the file-path code path.
    private static func loadAudioArray(path: String, providerName: String) throws -> [Float] {
        do {
            return try AudioProcessor.loadAudioAsFloatArray(
                fromPath: path,
                channelMode: .sumChannels(nil)
            )
        } catch {
            throw TranscriptionError.providerFailed(providerName, underlying: error)
        }
    }

    /// Zero-fill samples that fall inside any muted interval. Operates in
    /// place so a 1-hour mic file (~57 MB float array) doesn't double its
    /// memory footprint during the copy.
    private static func applyGate(
        to audio: inout [Float],
        sampleRate: Double,
        mutedIntervals: [MutedInterval]
    ) {
        for interval in mutedIntervals {
            let startSample = max(0, Int(interval.start * sampleRate))
            let endSample = min(audio.count, Int(interval.end * sampleRate))
            guard startSample < endSample else { continue }
            for i in startSample..<endSample {
                audio[i] = 0
            }
        }
    }

    private static func runTranscribeArray(
        box: KitBox,
        audioArray: [Float],
        language: String?,
        providerName: String,
        onProgress: (@Sendable (Double) -> Void)?
    ) async throws -> [TranscriptionResult] {
        // DecodingOptions intentionally identical to the audioPath path so
        // gated and ungated transcripts are byte-comparable wherever the
        // audio itself matches.
        let decode = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: language,
            skipSpecialTokens: true,
            withoutTimestamps: false,
            wordTimestamps: true,
            chunkingStrategy: .vad
        )

        let baseCompleted = box.kit.progress.completedUnitCount
        let baseTotal = box.kit.progress.totalUnitCount

        let pollerTask: Task<Void, Never>? = onProgress.map { report in
            Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                    let p = box.kit.progress
                    let completed = p.completedUnitCount - baseCompleted
                    let total = p.totalUnitCount - baseTotal
                    guard total > 0 else { continue }
                    let f = max(0.0, min(1.0, Double(completed) / Double(total)))
                    report(f)
                }
            }
        }
        defer { pollerTask?.cancel() }

        do {
            return try await box.kit.transcribe(audioArray: audioArray, decodeOptions: decode)
        } catch {
            throw TranscriptionError.providerFailed(providerName, underlying: error)
        }
    }

    private static func runDiarize(
        box: DiarizerBox,
        audioPath: String,
        whisperChunks: [TranscriptionResult],
        expectedSpeakerCount: Int?,
        providerName: String,
        onProgress: (@Sendable (Double) -> Void)?
    ) async throws -> [[SpeakerSegment]] {
        do {
            // SpeakerKit needs 16 kHz mono float32 — reuse WhisperKit's loader
            // so the resampling/channel-mixing matches what Whisper saw.
            let audio = try AudioProcessor.loadAudioAsFloatArray(
                fromPath: audioPath,
                channelMode: .sumChannels(nil)
            )
            // Pyannote v4 ships with `clusterDistanceThreshold = 0.6`. On
            // single-speaker recordings that's prone to over-split: a single
            // voice's natural pitch/energy variation can cross the boundary
            // and emerge as two synthetic speakers. Bumping to 0.7 keeps
            // conservative behaviour for genuinely-different voices while
            // merging the more borderline embeddings into one speaker.
            // When the user has set an explicit speaker count, pass that too;
            // it overrides the threshold's clustering when both are present.
            let options = PyannoteDiarizationOptions(
                numberOfSpeakers: expectedSpeakerCount,
                clusterDistanceThreshold: 0.7
            )
            let pyannoteCallback: (@Sendable (Progress) -> Void)?
            if let report = onProgress {
                pyannoteCallback = { (p: Progress) in report(p.fractionCompleted) }
            } else {
                pyannoteCallback = nil
            }
            let result = try await box.kit.diarize(
                audioArray: audio,
                options: options,
                progressCallback: pyannoteCallback
            )
            // `.segment` (one Whisper segment = one output) instead of
            // `.subsegment` because Thai (and CJK) word-level timestamps
            // from WhisperKit are at the BPE-token level, not real word
            // boundaries. `.subsegment` splits on inter-token gaps > 150ms,
            // which on Thai routinely cuts mid-word — producing orphan
            // vowels/tone marks like "ม" / "ีไมโครเซฟอรี่" or "เด" / "็ก".
            // `.segment` keeps the Whisper segment as the unit and labels
            // it with the dominant speaker via IoU matching; Whisper's VAD
            // chunking already cuts at silences, so a single segment
            // spanning two speakers is rare in practice.
            return result.addSpeakerInfo(
                to: whisperChunks,
                strategy: SpeakerInfoStrategy.segment
            )
        } catch {
            throw TranscriptionError.providerFailed(providerName, underlying: error)
        }
    }

    // MARK: - Mapping to our types

    private static func mapKnownSpeaker(
        chunks: [TranscriptionResult],
        options: TranscriptionOptions,
        providerName: String,
        modelVariant: String
    ) -> TranscriptResult {
        let speaker = options.knownSpeaker ?? SpeakerID.me

        var segments: [TranscriptSegment] = []
        var totalDuration: TimeInterval = 0
        var detectedLanguage: String? = options.language

        for chunk in chunks {
            if detectedLanguage == nil { detectedLanguage = chunk.language }

            for seg in chunk.segments {
                let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }

                let dur = TimeInterval(seg.end - seg.start)
                if HallucinationFilter.isHallucination(text: text, durationSeconds: dur) {
                    continue
                }

                segments.append(
                    TranscriptSegment(
                        start: TimeInterval(seg.start),
                        end: TimeInterval(seg.end),
                        speaker: speaker,
                        text: text,
                        source: options.source
                    )
                )
                totalDuration = max(totalDuration, TimeInterval(seg.end))
            }
        }

        return TranscriptResult(
            provider: providerName,
            model: modelVariant,
            language: detectedLanguage,
            duration: totalDuration,
            segments: segments
        )
    }

    private static func mapDiarized(
        groups: [[SpeakerSegment]],
        whisperChunks: [TranscriptionResult],
        options: TranscriptionOptions,
        providerName: String,
        modelVariant: String
    ) -> TranscriptResult {
        var segments: [TranscriptSegment] = []
        var totalDuration: TimeInterval = 0

        let language = options.language ?? whisperChunks.first?.language

        // SpeakerKit returns one inner array per Whisper chunk; flatten and emit
        // one TranscriptSegment per (contiguous-speaker, contiguous-time) span.
        for group in groups {
            for spk in group {
                let speakerID: SpeakerID = {
                    if let id = spk.speaker.speakerId {
                        return SpeakerID.diarized(id)
                    }
                    return SpeakerID(rawValue: "unknown")
                }()

                let text = spk.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let dur = TimeInterval(spk.endTime - spk.startTime)
                if !text.isEmpty,
                   !HallucinationFilter.isHallucination(text: text, durationSeconds: dur) {
                    segments.append(
                        TranscriptSegment(
                            start: TimeInterval(spk.startTime),
                            end: TimeInterval(spk.endTime),
                            speaker: speakerID,
                            text: text,
                            source: options.source
                        )
                    )
                }
                totalDuration = max(totalDuration, TimeInterval(spk.endTime))
            }
        }

        // Stable timeline ordering — diarization can emit segments in
        // speaker-grouped order, which is unhelpful for transcript playback.
        segments.sort { $0.start < $1.start }

        return TranscriptResult(
            provider: providerName,
            model: modelVariant,
            language: language,
            duration: totalDuration,
            segments: segments
        )
    }
}
