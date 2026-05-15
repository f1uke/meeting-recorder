import Foundation
import WhisperKit

/// Serial actor that drains pending meetings and writes their `embeddings.json`.
///
/// Triggered from two places:
///   - `TranscriptionSession` right after diarize finishes (post-record flow).
///   - `MeetingsLibrary.loadRecord()` when scanning a meeting that has a
///     transcript but no embeddings cache yet (lazy backfill).
///
/// One job at a time keeps Core ML memory bounded — pyannote embedder is ~30MB,
/// and concurrent Core ML inference on the ANE doesn't actually parallelize.
actor EmbeddingExtractionQueue {
    /// Notified `true` when a job starts and `false` when the last queued job
    /// drains. Drives MenuBarLabel's `.embedding` spinner state.
    var onActiveChanged: (@Sendable (Bool) -> Void)?

    private let embedder = SpeakerEmbedder()
    private var pending: [URL] = []
    private var processing: URL?
    private var drainTask: Task<Void, Never>?

    func setOnActiveChanged(_ callback: @escaping @Sendable (Bool) -> Void) {
        self.onActiveChanged = callback
    }

    /// Idempotent — re-enqueueing a folder already pending/processing is a no-op.
    func enqueue(meetingFolder: URL) {
        if processing == meetingFolder { return }
        if pending.contains(meetingFolder) { return }
        pending.append(meetingFolder)
        if drainTask == nil {
            onActiveChanged?(true)
            drainTask = Task { await self.drain() }
        }
    }

    private func drain() async {
        while let next = pending.first {
            pending.removeFirst()
            processing = next
            await process(folder: next)
            processing = nil
        }
        await embedder.unloadModels()
        drainTask = nil
        onActiveChanged?(false)
    }

    private func process(folder: URL) async {
        // Skip if cache already exists (e.g. enqueued twice via different paths)
        if (try? MeetingEmbeddingsFile.read(from: folder)) != nil {
            return
        }
        do {
            try await runExtraction(folder: folder)
        } catch {
            NSLog("[Meeting/Identity] extraction failed for %@: %@",
                  folder.lastPathComponent, String(describing: error))
            // Persist failure flag so we don't loop on the next scan
            let file = MeetingEmbeddingsFile(
                schemaVersion: 1,
                embedderModel: SpeakerEmbedder.modelTag,
                embeddings: [],
                rejectedIdentities: [],
                embeddingFailed: true
            )
            try? file.write(to: folder)
        }
    }

    private func runExtraction(folder: URL) async throws {
        let transcript = try MergedTranscript.read(from: folder)

        let audioURL = folder.appendingPathComponent("output.m4a")
        guard FileManager.default.fileExists(atPath: audioURL.path(percentEncoded: false)) else {
            throw EmbeddingExtractionError.noOutputAudio
        }
        let audio = try AudioProcessor.loadAudioAsFloatArray(
            fromPath: audioURL.path(percentEncoded: false),
            channelMode: .sumChannels(nil)
        )
        let sampleRate: Double = 16_000

        // Group diarized segments by speaker; skip `me` (mic stream — no diarization).
        let allSegments = transcript.segments
        let speakerGroups = Dictionary(grouping: allSegments) { $0.speaker }
            .filter { $0.key != SpeakerID.me }

        var embeddings: [SpeakerEmbedding] = []
        for (speakerID, segments) in speakerGroups {
            let slices = Self.sliceAudio(
                audio,
                segments: segments,
                allSegments: allSegments,
                sampleRate: sampleRate
            )
            let totalSeconds = Double(slices.reduce(0) { $0 + $1.count }) / sampleRate
            guard totalSeconds >= 5.0 else { continue }
            if let centroid = try await embedder.embed(audioSegments: slices) {
                embeddings.append(SpeakerEmbedding(
                    speakerID: speakerID,
                    centroid: centroid,
                    sampleSeconds: totalSeconds
                ))
            }
        }

        // Preserve any pre-existing rejection list (e.g. user reset only embeddings)
        var existing = (try? MeetingEmbeddingsFile.read(from: folder)) ?? MeetingEmbeddingsFile(
            schemaVersion: 1,
            embedderModel: SpeakerEmbedder.modelTag,
            embeddings: [],
            rejectedIdentities: [],
            embeddingFailed: false
        )
        existing.embeddings = embeddings
        existing.embeddingFailed = false
        existing.embedderModel = SpeakerEmbedder.modelTag
        try existing.write(to: folder)
    }

    /// For each segment of the target speaker, take its audio range minus a
    /// 200ms boundary margin. Skip segments whose conflict-overlap with
    /// other speakers exceeds 30% of their duration — those slices would
    /// contaminate the centroid.
    nonisolated static func sliceAudio(
        _ audio: [Float],
        segments: [TranscriptSegment],
        allSegments: [TranscriptSegment],
        sampleRate: Double
    ) -> [[Float]] {
        let margin: TimeInterval = 0.2
        let speakerIDs = Set(segments.map { $0.speaker })
        var slices: [[Float]] = []
        for seg in segments {
            let start = seg.start + margin
            let end = seg.end - margin
            guard end > start else { continue }

            let conflicts = allSegments.filter { other in
                !speakerIDs.contains(other.speaker)
                    && other.end > start && other.start < end
            }
            let conflictCoverage = conflicts.reduce(0.0) { acc, c in
                acc + (min(end, c.end) - max(start, c.start))
            }
            if conflictCoverage / (end - start) > 0.3 { continue }

            let startSample = Int(start * sampleRate)
            let endSample = min(audio.count, Int(end * sampleRate))
            guard endSample > startSample else { continue }
            slices.append(Array(audio[startSample..<endSample]))
        }
        return slices
    }
}

enum EmbeddingExtractionError: LocalizedError {
    case noOutputAudio
    var errorDescription: String? {
        switch self {
        case .noOutputAudio: "No output.m4a found in meeting folder"
        }
    }
}
