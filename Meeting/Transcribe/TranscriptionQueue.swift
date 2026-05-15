import Foundation
import Combine

// =============================================================================
// MARK: - Job model
// =============================================================================

/// A single transcription unit of work, scoped to one meeting folder.
/// Identified by `id` (UUID) so the UI can address it without races even
/// across rapid enqueue/cancel cycles.
struct TranscriptionJob: Identifiable, Sendable {
    let id: UUID
    let meetingFolder: URL
    /// Human-readable provider name captured at enqueue time. Surfaces in
    /// the Library row tooltip so users can tell which engine the job is
    /// using even after they've changed Settings.
    let providerName: String
    let modelName: String
    let expectedSpeakers: Int?
    let enqueuedAt: Date
    var startedAt: Date?
    var finishedAt: Date?
    var state: JobState
    /// Side-channel detail emitted by long-running providers (currently
    /// the Gemini batch poll loop). Independent of `state`'s stage so the
    /// UI can render "last check 12s ago — RUNNING" while the progress
    /// bar is pinned. Cleared on stage transitions.
    var lastStatus: TranscriptionSession.StageStatus?

    enum JobState: Equatable, Sendable {
        case queued
        /// Live progress while transcribing. `overall` is 0...1, weighted
        /// across the pipeline stages so the bar moves smoothly.
        case running(stage: TranscriptionSession.Stage, overall: Double)
        case done(transcriptURL: URL)
        case failed(message: String)
        case cancelled
    }

    var isTerminal: Bool {
        switch state {
        case .queued, .running: return false
        case .done, .failed, .cancelled: return true
        }
    }

    /// Convenience for the menu-bar label and the popover card — anything
    /// not yet terminal counts as "in flight".
    var isActive: Bool { !isTerminal }
}

// =============================================================================
// MARK: - Pending marker (restart recovery)
// =============================================================================

/// Sidecar written to `<meetingFolder>/transcription_pending.json` when a
/// job is enqueued. The worker deletes it on success / cancel /
/// permanent-fail. Surviving markers on app launch mark folders that need
/// re-enqueueing because a previous app run died mid-transcription.
///
/// Stop-only meetings deliberately don't write this file, so they're never
/// auto-resumed — only meetings the user explicitly asked to transcribe
/// come back after a crash.
struct TranscriptionPendingMarker: Codable, Sendable {
    let providerName: String
    let modelName: String
    let expectedSpeakers: Int?
    let enqueuedAt: Date

    private static let filename = "transcription_pending.json"

    static func url(in folder: URL) -> URL {
        folder.appendingPathComponent(filename)
    }

    static func exists(in folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: url(in: folder).path(percentEncoded: false))
    }

    static func read(from folder: URL) -> TranscriptionPendingMarker? {
        guard let data = try? Data(contentsOf: url(in: folder)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(TranscriptionPendingMarker.self, from: data)
    }

    func write(to folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: Self.url(in: folder), options: .atomic)
    }

    static func delete(in folder: URL) {
        try? FileManager.default.removeItem(at: url(in: folder))
    }
}

// =============================================================================
// MARK: - Queue
// =============================================================================

/// Background transcription queue. One worker, FIFO. Lives at app scope
/// so the menu-bar popover, Library, and notifications all see the same
/// list.
///
/// Concurrency model: the queue itself is `@MainActor` so view updates
/// are cheap. The actual transcription work runs inside `Task` blocks
/// that hop off the main actor — `provider.transcribe(...)` is async
/// non-isolated. We only flip back to MainActor to publish progress.
@MainActor
final class TranscriptionQueue: ObservableObject {
    @Published private(set) var jobs: [TranscriptionJob] = []

    /// Builds a fresh provider snapshot from current preferences. Captured
    /// at enqueue time so a settings change between enqueues uses the new
    /// engine for new jobs without yanking work out from under in-flight
    /// jobs.
    typealias ProviderSnapshot = (provider: TranscriptionProvider, name: String, model: String)
    private let providerFactory: @MainActor () -> ProviderSnapshot

    private let library: MeetingsLibrary
    private let toast: ToastPresenter
    /// Optional — when set, finished transcripts get queued for cross-meeting
    /// identity embedding extraction. Wired up by AppState at app launch;
    /// existing tests that construct TranscriptionQueue directly leave it nil
    /// and skip the embedding step.
    private let embeddingQueue: EmbeddingExtractionQueue?

    private var workerTask: Task<Void, Never>?
    /// Cancel handle for the currently-executing job's provider call.
    /// `cancel()` on a running job sets this; the worker observes the
    /// resulting `CancellationError` and marks the job `.cancelled`.
    private var runningJobTask: Task<Void, Never>?
    private var runningJobID: TranscriptionJob.ID?

    /// Provider instances captured per job. Kept off `TranscriptionJob`
    /// itself because providers aren't `Equatable` / `Codable` and
    /// `TranscriptionJob` ends up in `@Published` arrays.
    private var providers: [TranscriptionJob.ID: TranscriptionProvider] = [:]

    init(
        providerFactory: @escaping @MainActor () -> ProviderSnapshot,
        library: MeetingsLibrary,
        toast: ToastPresenter,
        embeddingQueue: EmbeddingExtractionQueue? = nil
    ) {
        self.providerFactory = providerFactory
        self.library = library
        self.toast = toast
        self.embeddingQueue = embeddingQueue
    }

    // MARK: - Public API

    /// Number of queued + running jobs. Drives the menu-bar label spinner
    /// and the popover's "background work" card visibility.
    var activeCount: Int {
        jobs.lazy.filter { $0.isActive }.count
    }

    var queuedCount: Int {
        jobs.lazy.filter { if case .queued = $0.state { return true }; return false }.count
    }

    var runningJob: TranscriptionJob? {
        jobs.first(where: { if case .running = $0.state { return true }; return false })
    }

    /// Active job for a given meeting folder, if any. Used by the Library
    /// row to render its status badge.
    func activeJob(forFolder folder: URL) -> TranscriptionJob? {
        let target = folder.standardizedFileURL
        return jobs.first(where: { $0.meetingFolder.standardizedFileURL == target && $0.isActive })
    }

    /// Most-recent job for a folder regardless of state — used to surface
    /// `failed` / `cancelled` rows so the user can retry from Library.
    func latestJob(forFolder folder: URL) -> TranscriptionJob? {
        let target = folder.standardizedFileURL
        return jobs.last(where: { $0.meetingFolder.standardizedFileURL == target })
    }

    /// Enqueue a folder for transcription. If an active job already exists
    /// for that folder this is a no-op (returns the existing id) — clicking
    /// "Retranscribe" twice shouldn't spawn duplicate work.
    @discardableResult
    func enqueue(meetingFolder: URL, expectedSpeakers: Int?) -> TranscriptionJob.ID {
        if let existing = activeJob(forFolder: meetingFolder) {
            return existing.id
        }
        // Drop any prior terminal entry for this folder — the row only
        // wants to show one job per meeting at a time. (Keep history
        // around on disk via transcript files; the queue is ephemeral.)
        jobs.removeAll(where: { $0.meetingFolder.standardizedFileURL == meetingFolder.standardizedFileURL })

        let snapshot = providerFactory()
        let job = TranscriptionJob(
            id: UUID(),
            meetingFolder: meetingFolder,
            providerName: snapshot.name,
            modelName: snapshot.model,
            expectedSpeakers: expectedSpeakers,
            enqueuedAt: Date(),
            state: .queued
        )
        jobs.append(job)
        providers[job.id] = snapshot.provider

        // Persist marker so the next launch can resume if app dies.
        let marker = TranscriptionPendingMarker(
            providerName: snapshot.name,
            modelName: snapshot.model,
            expectedSpeakers: expectedSpeakers,
            enqueuedAt: job.enqueuedAt
        )
        do {
            try marker.write(to: meetingFolder)
        } catch {
            NSLog("[Meeting/Queue] could not write pending marker: %@",
                  String(describing: error))
        }

        startWorker()
        return job.id
    }

    /// Cancel a queued or running job. Queued = removed instantly. Running
    /// = sends Task.cancel to the provider call; cloud providers honor
    /// URLSession cancellation so this lands quickly. Local WhisperKit
    /// may finish the chunk it's on before respecting cancellation.
    func cancel(_ jobID: TranscriptionJob.ID) {
        guard let idx = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        let job = jobs[idx]
        switch job.state {
        case .queued:
            jobs[idx].state = .cancelled
            jobs[idx].finishedAt = Date()
            providers.removeValue(forKey: jobID)
            TranscriptionPendingMarker.delete(in: job.meetingFolder)
        case .running:
            // The worker will catch cancellation and update state +
            // delete the marker.
            runningJobTask?.cancel()
        default:
            break
        }
    }

    /// Retry a failed job. Re-enqueues with the same params using a fresh
    /// provider built from current settings — so the user can tweak
    /// engine / model and retry without juggling settings.
    func retry(_ jobID: TranscriptionJob.ID) {
        guard let job = jobs.first(where: { $0.id == jobID }) else { return }
        guard case .failed = job.state else { return }
        jobs.removeAll(where: { $0.id == jobID })
        providers.removeValue(forKey: jobID)
        enqueue(meetingFolder: job.meetingFolder, expectedSpeakers: job.expectedSpeakers)
    }

    /// Drop a terminal job from the visible list. Used by the Library row
    /// dismiss button on done/failed/cancelled states.
    func dismiss(_ jobID: TranscriptionJob.ID) {
        guard let job = jobs.first(where: { $0.id == jobID }) else { return }
        guard job.isTerminal else { return }
        jobs.removeAll(where: { $0.id == jobID })
        providers.removeValue(forKey: jobID)
    }

    /// Scan the meetings root for stale pending markers. Used at app
    /// launch to resume jobs that died with the previous app process.
    /// Skips folders without audio (incomplete recordings) or with a
    /// transcript already present (marker leak).
    func scanAndEnqueueOrphans(meetingsRoot: URL) {
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: meetingsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        for folder in folders {
            guard TranscriptionPendingMarker.exists(in: folder) else { continue }
            let mic = folder.appendingPathComponent("mic.m4a")
            let output = folder.appendingPathComponent("output.m4a")
            let transcript = folder.appendingPathComponent("transcript.json")
            let micExists = FileManager.default.fileExists(atPath: mic.path(percentEncoded: false))
            let outputExists = FileManager.default.fileExists(atPath: output.path(percentEncoded: false))
            let transcriptExists = FileManager.default.fileExists(atPath: transcript.path(percentEncoded: false))
            if transcriptExists || !micExists || !outputExists {
                // Marker is stale — clean it and move on.
                TranscriptionPendingMarker.delete(in: folder)
                continue
            }
            let marker = TranscriptionPendingMarker.read(from: folder)
            enqueue(meetingFolder: folder, expectedSpeakers: marker?.expectedSpeakers)
        }
    }

    // MARK: - Worker

    private func startWorker() {
        if workerTask != nil { return }
        workerTask = Task { @MainActor [weak self] in
            await self?.workerLoop()
            self?.workerTask = nil
        }
    }

    private func workerLoop() async {
        while let nextIdx = jobs.firstIndex(where: { if case .queued = $0.state { return true }; return false }) {
            await runJob(at: nextIdx)
        }
    }

    /// Execute one job. Replaces the body of the old
    /// `TranscriptionSession.run()` since the queue now owns per-job state.
    private func runJob(at index: Int) async {
        guard index < jobs.count else { return }
        let jobID = jobs[index].id
        let folder = jobs[index].meetingFolder
        let expectedSpeakers = jobs[index].expectedSpeakers
        guard let provider = providers[jobID] else {
            jobs[index].state = .failed(message: "Provider snapshot lost")
            jobs[index].finishedAt = Date()
            TranscriptionPendingMarker.delete(in: folder)
            return
        }

        jobs[index].startedAt = Date()
        update(jobID: jobID) {
            $0.state = .running(stage: .loadingModels, overall: 0)
        }

        let micURL = folder.appendingPathComponent("mic.m4a")
        let outputURL = folder.appendingPathComponent("output.m4a")
        let languageCode = AppPreferences.shared.transcriptionLanguage.whisperCode
        let micGateIntervals = MicGateFile.read(from: folder)?.muted

        // Wrap the work in a Task so we have a cancel handle the queue's
        // public cancel() can target.
        let work = Task<Void, Never> { [weak self, jobID, provider] in
            guard let self else { return }
            do {
                try await self.executeTranscription(
                    jobID: jobID,
                    folder: folder,
                    micURL: micURL,
                    outputURL: outputURL,
                    languageCode: languageCode,
                    micGateIntervals: micGateIntervals,
                    expectedSpeakers: expectedSpeakers,
                    provider: provider
                )
                await MainActor.run {
                    self.markDone(jobID: jobID)
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.markCancelled(jobID: jobID)
                }
            } catch let urlErr as URLError where urlErr.code == .cancelled {
                await MainActor.run {
                    self.markCancelled(jobID: jobID)
                }
            } catch {
                await MainActor.run {
                    self.markFailed(jobID: jobID, error: error)
                }
            }
        }
        runningJobID = jobID
        runningJobTask = work
        await work.value
        runningJobID = nil
        runningJobTask = nil

        // Free the provider so multi-GB CoreML weights (local engine)
        // don't stay resident between jobs.
        let releasedProvider = providers.removeValue(forKey: jobID)
        if let releasedProvider {
            Task.detached { await releasedProvider.unloadModels() }
        }
    }

    private func executeTranscription(
        jobID: TranscriptionJob.ID,
        folder: URL,
        micURL: URL,
        outputURL: URL,
        languageCode: String?,
        micGateIntervals: [MutedInterval]?,
        expectedSpeakers: Int?,
        provider: TranscriptionProvider
    ) async throws {
        // Multi-stream entry. Providers that benefit from bundling (Gemini
        // Batch API) override `transcribeBatch` to run every stream's
        // chunks through one server-side job; the default extension impl
        // falls back to sequential `transcribe()` calls so local engines
        // (WhisperKit + SpeakerKit, GPU-bound) keep their existing
        // mic-then-output ordering.
        let micOptions = TranscriptionOptions(
            language: languageCode,
            withDiarization: false,
            knownSpeaker: .me,
            source: .mic,
            mutedIntervals: micGateIntervals,
            referenceAudioURL: outputURL,
            normalizeLoudness: true
        )
        let outputOptions = TranscriptionOptions(
            language: languageCode,
            withDiarization: true,
            knownSpeaker: nil,
            source: .meetingOutput,
            expectedSpeakerCount: expectedSpeakers
        )

        publishStage(jobID: jobID, stage: .transcribingBatch, fraction: 0)
        let results = try await provider.transcribeBatch(
            streams: [
                TranscribeStream(audioURL: micURL, options: micOptions),
                TranscribeStream(audioURL: outputURL, options: outputOptions),
            ],
            progress: { [weak self] fraction in
                Task { @MainActor in
                    self?.publishStage(jobID: jobID, stage: .transcribingBatch, fraction: fraction)
                }
            },
            status: { [weak self] status in
                Task { @MainActor in
                    self?.publishStatus(jobID: jobID, status: status)
                }
            }
        )
        guard let mic = results[micURL], let output = results[outputURL] else {
            throw TranscriptionError.providerFailed(
                provider.name,
                underlying: NSError(domain: "TranscriptionQueue", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "transcribeBatch did not return a result for one of the requested streams"
                ])
            )
        }

        // Merge + write — fast, no progress emit needed.
        publishStage(jobID: jobID, stage: .merging, fraction: 1)
        let merged = TranscriptMerger.merge(mic: mic, output: output)
        publishStage(jobID: jobID, stage: .writing, fraction: 1)
        try TranscriptExporter.writeAll(merged, in: folder)
    }

    // MARK: - State publish helpers

    private func update(jobID: TranscriptionJob.ID, _ mutate: (inout TranscriptionJob) -> Void) {
        guard let idx = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        mutate(&jobs[idx])
    }

    /// Republish progress for a running job, but only when overall has
    /// shifted enough to be worth a re-render. Mirrors the old
    /// `TranscriptionSession.makeProgressReporter` 0.5% delta filter.
    private func publishStage(jobID: TranscriptionJob.ID, stage: TranscriptionSession.Stage, fraction: Double) {
        guard let idx = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        let band = stage.progressRange
        let clamped = max(0, min(1, fraction))
        let newOverall = band.start + (band.end - band.start) * clamped
        if case let .running(currentStage, currentOverall) = jobs[idx].state {
            // Skip republish if same stage and tiny delta.
            if currentStage == stage,
               abs(newOverall - currentOverall) < 0.005,
               clamped < 1 {
                return
            }
            // Stage moved on — drop any stage-specific status detail so
            // the UI doesn't show e.g. "Polling Gemini batch" while the
            // pipeline is already merging.
            if currentStage != stage {
                jobs[idx].lastStatus = nil
            }
        }
        jobs[idx].state = .running(stage: stage, overall: newOverall)
    }

    /// Republish the latest provider-side status for a running job. No
    /// rate-limiting — providers are expected to emit at most every few
    /// seconds (Gemini's poll loop is the only caller today).
    private func publishStatus(jobID: TranscriptionJob.ID, status: TranscriptionSession.StageStatus) {
        guard let idx = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        jobs[idx].lastStatus = status
    }

    private func markDone(jobID: TranscriptionJob.ID) {
        guard let idx = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        let folder = jobs[idx].meetingFolder
        let transcriptURL = folder.appendingPathComponent("transcript.md")
        jobs[idx].state = .done(transcriptURL: transcriptURL)
        jobs[idx].finishedAt = Date()
        TranscriptionPendingMarker.delete(in: folder)

        // Refresh the library so duration / speakers fill in for this row.
        library.rescan()

        // Kick off acoustic embedding extraction in the background. Idempotent —
        // if the meeting already has embeddings.json (re-transcribe case) the
        // queue's process() skips it.
        if let embeddingQueue {
            Task { await embeddingQueue.enqueue(meetingFolder: folder) }
        }

        // Toast — pick up the freshly-rescanned record so we have the
        // accurate title / duration / speaker count. (If the scan hasn't
        // landed yet for whatever reason, fall back to a folder-name toast.)
        if let record = library.meetings.first(where: { $0.folder == folder }) {
            toast.showTranscriptReady(
                meetingTitle: record.title,
                durationText: formatDuration(record.duration),
                speakerCount: record.speakerCount,
                folder: folder
            )
        }
    }

    private func markFailed(jobID: TranscriptionJob.ID, error: Error) {
        guard let idx = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        let folder = jobs[idx].meetingFolder
        jobs[idx].state = .failed(message: error.localizedDescription)
        jobs[idx].finishedAt = Date()
        // Failed = leave the marker in place. Next launch will resume; user
        // can also click Retry from the Library row to try again now.
        // (Permanent failures the user wants to dismiss are removed via
        // dismiss(_:) which also clears the marker.)
    }

    private func markCancelled(jobID: TranscriptionJob.ID) {
        guard let idx = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        let folder = jobs[idx].meetingFolder
        jobs[idx].state = .cancelled
        jobs[idx].finishedAt = Date()
        TranscriptionPendingMarker.delete(in: folder)
    }

    private func formatDuration(_ d: TimeInterval?) -> String {
        guard let d else { return "" }
        let total = Int(d)
        let h = total / 3600
        let m = (total / 60) % 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }
}
