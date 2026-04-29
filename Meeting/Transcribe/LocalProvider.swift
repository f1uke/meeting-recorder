import Foundation
import WhisperKit
import SpeakerKit

// Local-first transcription provider. Loads Whisper + (optional) SpeakerKit
// CoreML models once and runs:
//   - mic.wav   →  WhisperKit + options.knownSpeaker = "me"
//   - output.wav →  WhisperKit + SpeakerKit (pyannote v4) → speaker_0/1/...
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

    func transcribe(audioURL: URL, options: TranscriptionOptions) async throws -> TranscriptResult {
        guard FileManager.default.fileExists(atPath: audioURL.path(percentEncoded: false)) else {
            throw TranscriptionError.audioMissing(audioURL)
        }

        let path = audioURL.path(percentEncoded: false)
        let kit = try await loadKit()

        // Always run Whisper for text + word timestamps.
        let chunks = try await Self.runTranscribe(
            box: kit,
            audioPath: path,
            language: options.language,
            providerName: name
        )

        if options.withDiarization {
            let dia = try await loadDiarizer()
            let labeledGroups = try await Self.runDiarize(
                box: dia,
                audioPath: path,
                whisperChunks: chunks,
                expectedSpeakerCount: options.expectedSpeakerCount,
                providerName: name
            )
            return Self.mapDiarized(
                groups: labeledGroups,
                whisperChunks: chunks,
                options: options,
                providerName: name,
                modelVariant: modelVariant
            )
        }

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
        providerName: String
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
        do {
            return try await box.kit.transcribe(audioPath: audioPath, decodeOptions: decode)
        } catch {
            throw TranscriptionError.providerFailed(providerName, underlying: error)
        }
    }

    private static func runDiarize(
        box: DiarizerBox,
        audioPath: String,
        whisperChunks: [TranscriptionResult],
        expectedSpeakerCount: Int?,
        providerName: String
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
            let result = try await box.kit.diarize(audioArray: audio, options: options)
            return result.addSpeakerInfo(
                to: whisperChunks,
                strategy: SpeakerInfoStrategy.subsegment
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
        var words: [TranscriptWord] = []
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

                for w in seg.words ?? [] {
                    words.append(
                        TranscriptWord(
                            word: w.word,
                            start: TimeInterval(w.start),
                            end: TimeInterval(w.end),
                            speaker: speaker
                        )
                    )
                }
            }
        }

        return TranscriptResult(
            provider: providerName,
            model: modelVariant,
            language: detectedLanguage,
            duration: totalDuration,
            segments: segments,
            words: words.isEmpty ? nil : words
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
        var words: [TranscriptWord] = []
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

                for sw in spk.speakerWords {
                    words.append(
                        TranscriptWord(
                            word: sw.wordTiming.word,
                            start: TimeInterval(sw.wordTiming.start),
                            end: TimeInterval(sw.wordTiming.end),
                            speaker: sw.speaker.speakerId.map { SpeakerID.diarized($0) }
                        )
                    )
                }
            }
        }

        // Stable timeline ordering — diarization can emit segments in
        // speaker-grouped order, which is unhelpful for transcript playback.
        segments.sort { $0.start < $1.start }
        words.sort { $0.start < $1.start }

        return TranscriptResult(
            provider: providerName,
            model: modelVariant,
            language: language,
            duration: totalDuration,
            segments: segments,
            words: words.isEmpty ? nil : words
        )
    }
}
