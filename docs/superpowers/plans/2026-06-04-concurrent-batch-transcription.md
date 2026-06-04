# Concurrent Batch Transcription Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let Gemini batch transcription jobs submit and poll concurrently instead of serializing behind one queue worker, while keeping the local engine strictly serial.

**Architecture:** Add an `ExecutionLane` capability to `TranscriptionProvider`. The queue runs an exclusive (serial) lane for local/sync jobs and a concurrent lane for batch jobs. A shared `BatchUploadLimiter` caps how many jobs upload at once; polling is unbounded.

**Tech Stack:** Swift 6 / SwiftUI, XCTest, XcodeGen. Spec: `docs/superpowers/specs/2026-06-04-concurrent-batch-transcription-design.md`.

---

## File Structure

- **Create** `Meeting/Transcribe/BatchUploadLimiter.swift` — shared async semaphore capping concurrent upload phases.
- **Modify** `Meeting/Transcribe/TranscriptionProvider.swift` — add `ExecutionLane` enum + `executionLane` protocol requirement with `.exclusive` default.
- **Modify** `Meeting/Transcribe/GeminiProvider.swift` — declare `executionLane`; acquire/release the limiter around the fresh upload+submit phase.
- **Modify** `Meeting/Transcribe/TranscriptionQueue.swift` — two-lane worker; `runningTasks` dictionary.
- **Modify** `Meeting/App/PopoverViews.swift` — summarize when more than one job runs.
- **Create** `MeetingTests/BatchUploadLimiterTests.swift` — cap + cancellation tests.
- **Create** `MeetingTests/TranscriptionQueueLaneTests.swift` — concurrency vs. serialization tests.

---

## Task 1: ExecutionLane capability on the provider protocol

**Files:**
- Modify: `Meeting/Transcribe/TranscriptionProvider.swift` (protocol at line 119, extension at line 155)
- Modify: `Meeting/Transcribe/GeminiProvider.swift:34-53` (add computed property near `name`)
- Test: `MeetingTests/TranscriptionQueueLaneTests.swift` (new — also used by Task 4)

- [ ] **Step 1: Write the failing test**

Create `MeetingTests/TranscriptionQueueLaneTests.swift`:

```swift
import XCTest
@testable import Meeting

final class TranscriptionQueueLaneTests: XCTestCase {

    func test_gemini_batchMode_isConcurrentCloudLane() {
        let batch = GeminiProvider(apiKey: "k", glossary: "", modelName: "gemini-2.5-pro", useBatchAPI: true)
        XCTAssertEqual(batch.executionLane, .concurrentCloud)
    }

    func test_gemini_syncMode_isExclusiveLane() {
        let sync = GeminiProvider(apiKey: "k", glossary: "", modelName: "gemini-2.5-pro", useBatchAPI: false)
        XCTAssertEqual(sync.executionLane, .exclusive)
    }

    func test_defaultProvider_isExclusiveLane() {
        XCTAssertEqual(LaneDefaultStub().executionLane, .exclusive)
    }
}

/// Minimal conformer that implements only the required members and inherits
/// the default `executionLane`. Proves the protocol default is `.exclusive`.
private struct LaneDefaultStub: TranscriptionProvider {
    let name = "Stub"
    func transcribe(audioURL: URL, options: TranscriptionOptions,
                    progress: (@Sendable (Double) -> Void)?) async throws -> TranscriptResult {
        fatalError("not exercised")
    }
}
```

- [ ] **Step 2: Run test to verify it fails (does not compile)**

Run:
```bash
xcodegen generate
xcodebuild -project Meeting.xcodeproj -scheme Meeting -destination 'platform=macOS' \
  -only-testing:MeetingTests/TranscriptionQueueLaneTests test 2>&1 | tail -20
```
Expected: compile failure — `ExecutionLane` and `executionLane` are undefined.

- [ ] **Step 3: Add the enum and protocol requirement**

In `Meeting/Transcribe/TranscriptionProvider.swift`, immediately above `protocol TranscriptionProvider` (line 119):

```swift
/// Scheduling class for a provider. Tells `TranscriptionQueue` whether a job
/// must run alone (local GPU/RAM-bound engines, rate-sensitive sync calls) or
/// can run alongside others (server-side batch work, where the heavy compute
/// is on the remote side and the local cost is just polling).
enum ExecutionLane: Sendable, Equatable {
    case exclusive
    case concurrentCloud
}
```

Add the requirement inside the protocol (after `var name: String { get }`, line 121):

```swift
    /// How the queue may schedule this provider's jobs. Defaults to
    /// `.exclusive` (one at a time) via the extension below.
    var executionLane: ExecutionLane { get }
```

Add the default to the `extension TranscriptionProvider` block (after line 156's `unloadModels`):

```swift
    var executionLane: ExecutionLane { .exclusive }
```

- [ ] **Step 4: Override in GeminiProvider**

In `Meeting/Transcribe/GeminiProvider.swift`, after `nonisolated let name: String` (line 22):

```swift
    /// Batch mode runs entirely on Google's servers, so several batch jobs can
    /// be in flight at once. Sync mode makes interactive API calls per chunk
    /// and stays exclusive to avoid hammering rate limits.
    nonisolated var executionLane: ExecutionLane { useBatchAPI ? .concurrentCloud : .exclusive }
```

(`useBatchAPI` is a stored `let` at line 27 — readable from a `nonisolated` computed property.)

- [ ] **Step 5: Run tests to verify they pass**

Run:
```bash
xcodebuild -project Meeting.xcodeproj -scheme Meeting -destination 'platform=macOS' \
  -only-testing:MeetingTests/TranscriptionQueueLaneTests test 2>&1 | tail -20
```
Expected: 3 tests PASS.

- [ ] **Step 6: Commit**

```bash
git add Meeting/Transcribe/TranscriptionProvider.swift Meeting/Transcribe/GeminiProvider.swift MeetingTests/TranscriptionQueueLaneTests.swift Meeting.xcodeproj
git commit -m "Add ExecutionLane capability to TranscriptionProvider"
```

---

## Task 2: BatchUploadLimiter

**Files:**
- Create: `Meeting/Transcribe/BatchUploadLimiter.swift`
- Test: `MeetingTests/BatchUploadLimiterTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `MeetingTests/BatchUploadLimiterTests.swift`:

```swift
import XCTest
@testable import Meeting

final class BatchUploadLimiterTests: XCTestCase {

    func test_acquiresUpToLimitWithoutBlocking() async throws {
        let limiter = BatchUploadLimiter(limit: 2)
        try await limiter.acquire()
        try await limiter.acquire()   // both slots free — returns immediately
        // If we got here without hanging, the two acquires succeeded.
        limiter.release()
        limiter.release()
    }

    func test_thirdAcquireBlocksUntilRelease() async throws {
        let limiter = BatchUploadLimiter(limit: 2)
        try await limiter.acquire()
        try await limiter.acquire()

        let thirdProceeded = expectation(description: "third acquire proceeded")
        let task = Task {
            try await limiter.acquire()
            thirdProceeded.fulfill()
        }

        // Should NOT proceed while both slots are held.
        let blocked = expectation(description: "still blocked")
        blocked.isInverted = true
        let probe = Task { try? await Task.sleep(nanoseconds: 200_000_000); blocked.fulfill() }
        await fulfillment(of: [blocked], timeout: 0.4)
        probe.cancel()

        // Releasing one slot lets the third proceed.
        limiter.release()
        await fulfillment(of: [thirdProceeded], timeout: 1.0)
        _ = task
    }

    func test_acquireHonorsCancellation() async throws {
        let limiter = BatchUploadLimiter(limit: 1)
        try await limiter.acquire()   // sole slot taken

        let threw = expectation(description: "cancelled acquire threw")
        let task = Task {
            do { try await limiter.acquire(); XCTFail("should not acquire") }
            catch is CancellationError { threw.fulfill() }
            catch { XCTFail("unexpected error: \(error)") }
        }
        // Give the task a moment to park on the waiter, then cancel.
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        await fulfillment(of: [threw], timeout: 1.0)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail (do not compile)**

Run:
```bash
xcodegen generate
xcodebuild -project Meeting.xcodeproj -scheme Meeting -destination 'platform=macOS' \
  -only-testing:MeetingTests/BatchUploadLimiterTests test 2>&1 | tail -20
```
Expected: compile failure — `BatchUploadLimiter` undefined.

- [ ] **Step 3: Implement the limiter**

Create `Meeting/Transcribe/BatchUploadLimiter.swift`:

```swift
import Foundation

/// A FIFO async counting semaphore that caps how many transcription jobs may
/// be in their upload phase at once. Shared across all `GeminiProvider`
/// instances (which are created per-job) via `BatchUploadLimiter.shared`.
///
/// Not an actor: `release()` must be callable synchronously (e.g. from a
/// `defer`), so state is guarded by an `NSLock` instead of actor isolation.
final class BatchUploadLimiter: @unchecked Sendable {
    /// App-wide limiter. Cap chosen so a couple of jobs upload concurrently
    /// (each already parallelizes its own chunk uploads) without saturating
    /// bandwidth. Tune here.
    static let shared = BatchUploadLimiter(limit: 2)

    private let lock = NSLock()
    private var available: Int
    private var waiters: [(id: UUID, cont: CheckedContinuation<Void, Error>)] = []

    init(limit: Int) {
        precondition(limit > 0)
        self.available = limit
    }

    /// Take a slot, suspending if none are free. Throws `CancellationError`
    /// if the awaiting task is cancelled while parked.
    func acquire() async throws {
        try Task.checkCancellation()
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                lock.lock()
                if available > 0 {
                    available -= 1
                    lock.unlock()
                    cont.resume()
                } else {
                    waiters.append((id, cont))
                    lock.unlock()
                }
            }
        } onCancel: {
            lock.lock()
            if let idx = waiters.firstIndex(where: { $0.id == id }) {
                let cont = waiters.remove(at: idx).cont
                lock.unlock()
                cont.resume(throwing: CancellationError())
            } else {
                lock.unlock()
            }
        }
    }

    /// Return a slot, waking the oldest waiter if any.
    func release() {
        lock.lock()
        if !waiters.isEmpty {
            let cont = waiters.removeFirst().cont
            lock.unlock()
            cont.resume()
        } else {
            available += 1
            lock.unlock()
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run:
```bash
xcodebuild -project Meeting.xcodeproj -scheme Meeting -destination 'platform=macOS' \
  -only-testing:MeetingTests/BatchUploadLimiterTests test 2>&1 | tail -20
```
Expected: 3 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Meeting/Transcribe/BatchUploadLimiter.swift MeetingTests/BatchUploadLimiterTests.swift Meeting.xcodeproj
git commit -m "Add BatchUploadLimiter shared upload throttle"
```

---

## Task 3: Throttle the Gemini upload phase

This is I/O glue around live network calls, so it has no standalone unit test —
the limiter's own tests (Task 2) cover the throttle logic, and Task 6's full
build verifies it compiles. Correctness of the phase boundary is verified by
reading the code: the slot is released before `pollBatch`.

**Files:**
- Modify: `Meeting/Transcribe/GeminiProvider.swift` (in `transcribeCombinedBatch`, lines ~935 and ~1090)

- [ ] **Step 1: Acquire a slot before chunk prep**

In `transcribeCombinedBatch`, find `onProgress?(0)` (line ~935). Immediately AFTER it, add:

```swift
        // Cap how many jobs upload concurrently (polling afterwards is
        // unbounded). The resume path below never reaches here, so resumed
        // batches poll without taking a slot.
        try await BatchUploadLimiter.shared.acquire()
        var uploadSlotHeld = true
        func releaseUploadSlot() {
            if uploadSlotHeld { uploadSlotHeld = false; BatchUploadLimiter.shared.release() }
        }
        defer { releaseUploadSlot() }   // safety net: releases on any throw before the explicit release
```

- [ ] **Step 2: Release the slot right after submit, before polling**

Find the submit + progress lines (~1090):

```swift
        let batchName = try await submitBatch(inputFileName: jsonlFile.name)
        onProgress?(submitEnd)
```

Immediately AFTER `onProgress?(submitEnd)` add:

```swift
        // Batch is now on Google's queue — free the upload slot so another
        // job can upload while we poll (poll runs outside the limiter).
        releaseUploadSlot()
```

The function-scope `defer` from Step 1 becomes a no-op once `releaseUploadSlot()`
has run (it is idempotent), and still fires if any step between acquire and the
explicit release throws.

- [ ] **Step 3: Verify the acquire is on the fresh path only**

Read lines ~886-915: the resume block (`resumeBatchFromMarker`) `return`s before
reaching `onProgress?(0)`. Confirm the new `acquire()` sits AFTER that resume
block (it does — it's just before chunk prep). No code change; this is a
read-only confirmation step.

- [ ] **Step 4: Build to verify it compiles**

Run:
```bash
xcodebuild -project Meeting.xcodeproj -scheme Meeting -configuration Debug \
  -destination 'platform=macOS' CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -15
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Meeting/Transcribe/GeminiProvider.swift
git commit -m "Throttle Gemini batch upload phase via BatchUploadLimiter"
```

---

## Task 4: Two-lane TranscriptionQueue worker

**Files:**
- Modify: `Meeting/Transcribe/TranscriptionQueue.swift` (fields ~131-136, `enqueue` ~225, `cancel` ~242-245, worker section ~299-383)
- Test: `MeetingTests/TranscriptionQueueLaneTests.swift` (append to the file from Task 1)

- [ ] **Step 1: Write the failing tests**

Append to `MeetingTests/TranscriptionQueueLaneTests.swift` (inside the class, after the existing tests):

```swift
    @MainActor
    func test_concurrentCloudJobs_startInParallel() async throws {
        let root = Self.makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let allStarted = expectation(description: "all 3 started")
        allStarted.expectedFulfillmentCount = 3

        let queue = TranscriptionQueue(
            providerFactory: { (FakeQueueProvider(lane: .concurrentCloud, onStart: { _ in allStarted.fulfill() }), "Fake", "m") },
            library: MeetingsLibrary(meetingsRoot: root),
            toast: ToastPresenter()
        )

        var ids: [UUID] = []
        for i in 0..<3 {
            let folder = root.appendingPathComponent("m\(i)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            ids.append(queue.enqueue(meetingFolder: folder, expectedSpeakers: nil))
        }

        // Each fake blocks after signalling start; serial scheduling would only
        // ever start one. Three starts within the timeout proves parallelism.
        await fulfillment(of: [allStarted], timeout: 3.0)
        for id in ids { queue.cancel(id) }
    }

    @MainActor
    func test_exclusiveJobs_startOneAtATime() async throws {
        let root = Self.makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let firstStarted = expectation(description: "first started")
        let secondStarted = expectation(description: "second started")
        secondStarted.isInverted = true   // must NOT start while first is running

        let counter = StartCounter()
        let queue = TranscriptionQueue(
            providerFactory: {
                (FakeQueueProvider(lane: .exclusive, onStart: { _ in
                    switch counter.bump() {
                    case 1: firstStarted.fulfill()
                    case 2: secondStarted.fulfill()
                    default: break
                    }
                }), "Fake", "m")
            },
            library: MeetingsLibrary(meetingsRoot: root),
            toast: ToastPresenter()
        )

        var ids: [UUID] = []
        for i in 0..<2 {
            let folder = root.appendingPathComponent("e\(i)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            ids.append(queue.enqueue(meetingFolder: folder, expectedSpeakers: nil))
        }

        await fulfillment(of: [firstStarted], timeout: 3.0)
        await fulfillment(of: [secondStarted], timeout: 0.5)   // inverted: passes if it never starts
        for id in ids { queue.cancel(id) }
    }

    static func makeTempRoot() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("queue-lane-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// Thread-safe start counter for the serialization test.
private final class StartCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() -> Int { lock.lock(); n += 1; let v = n; lock.unlock(); return v }
}

/// Test provider: signals when its batch begins, then blocks until cancelled so
/// the queue's scheduling (parallel vs. serial) is observable via start order.
private struct FakeQueueProvider: TranscriptionProvider {
    let name = "Fake"
    let lane: ExecutionLane
    let onStart: @Sendable (URL) -> Void
    var executionLane: ExecutionLane { lane }

    func transcribe(audioURL: URL, options: TranscriptionOptions,
                    progress: (@Sendable (Double) -> Void)?) async throws -> TranscriptResult {
        fatalError("not exercised")
    }

    func transcribeBatch(streams: [TranscribeStream],
                         progress: (@Sendable (Double) -> Void)?,
                         status: (@Sendable (TranscriptionSession.StageStatus) -> Void)?) async throws -> [URL: TranscriptResult] {
        onStart(streams.first?.audioURL ?? URL(fileURLWithPath: "/"))
        try await Task.sleep(nanoseconds: 30_000_000_000)   // block until the test cancels us
        return [:]
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:
```bash
xcodegen generate
xcodebuild -project Meeting.xcodeproj -scheme Meeting -destination 'platform=macOS' \
  -only-testing:MeetingTests/TranscriptionQueueLaneTests/test_concurrentCloudJobs_startInParallel test 2>&1 | tail -25
```
Expected: FAIL — `test_concurrentCloudJobs_startInParallel` times out (only 1 of 3 starts under the current serial worker).

- [ ] **Step 3: Replace the single-task fields**

In `Meeting/Transcribe/TranscriptionQueue.swift`, replace lines 131-136:

```swift
    private var workerTask: Task<Void, Never>?
    /// Cancel handle for the currently-executing job's provider call.
    /// `cancel()` on a running job sets this; the worker observes the
    /// resulting `CancellationError` and marks the job `.cancelled`.
    private var runningJobTask: Task<Void, Never>?
    private var runningJobID: TranscriptionJob.ID?
```

with:

```swift
    /// Serial worker for the `.exclusive` lane (local engine, sync cloud).
    private var workerTask: Task<Void, Never>?
    /// Cancel handles for every running job in any lane, keyed by job id.
    /// `cancel()` targets the entry to stop the provider call; the job's task
    /// observes `CancellationError` and marks itself `.cancelled`.
    private var runningTasks: [TranscriptionJob.ID: Task<Void, Never>] = [:]
```

- [ ] **Step 4: Dispatch by lane on enqueue**

In `enqueue(...)`, replace the final `startWorker()` (line ~225) with:

```swift
        switch providers[job.id]?.executionLane ?? .exclusive {
        case .exclusive:
            startExclusiveWorker()
        case .concurrentCloud:
            launchConcurrentJob(jobID: job.id)
        }
```

- [ ] **Step 5: Update cancel() to use the dictionary**

In `cancel(_:)`, replace the `.running` case body (line ~242-245):

```swift
        case .running:
            // The worker will catch cancellation and update state +
            // delete the marker.
            runningJobTask?.cancel()
```

with:

```swift
        case .running:
            // The job's task catches cancellation and updates state +
            // deletes the marker.
            runningTasks[jobID]?.cancel()
```

- [ ] **Step 6: Rewrite the worker section**

Replace the entire worker section — from `// MARK: - Worker` through the end of `runJob(at:)` (lines ~299-383) — with:

```swift
    // MARK: - Worker

    /// Ensure the serial exclusive-lane loop is running. No-op if already up.
    private func startExclusiveWorker() {
        if workerTask != nil { return }
        workerTask = Task { @MainActor [weak self] in
            await self?.exclusiveLoop()
            self?.workerTask = nil
        }
    }

    /// Run `.exclusive` jobs one at a time, FIFO. Ignores `.concurrentCloud`
    /// jobs — those are launched immediately by `launchConcurrentJob`. Each job
    /// runs in a stored task (like the concurrent lane) so `cancel()` can stop
    /// a running local job; the loop awaits it before picking the next.
    private func exclusiveLoop() async {
        while let job = jobs.first(where: { isQueuedExclusive($0) }) {
            let jobID = job.id
            let task = Task { @MainActor [weak self] in
                await self?.runJob(jobID: jobID)
            }
            runningTasks[jobID] = task
            await task.value
        }
    }

    private func isQueuedExclusive(_ job: TranscriptionJob) -> Bool {
        guard case .queued = job.state else { return false }
        return (providers[job.id]?.executionLane ?? .exclusive) == .exclusive
    }

    /// Launch a concurrent-lane (batch) job in its own task immediately. The
    /// upload phase self-throttles via `BatchUploadLimiter`; polling is
    /// unbounded, so many of these can be in flight at once.
    private func launchConcurrentJob(jobID: TranscriptionJob.ID) {
        let task = Task { @MainActor [weak self] in
            await self?.runJob(jobID: jobID)
        }
        runningTasks[jobID] = task
    }

    /// Execute one job by id. Resolves the job freshly (indices shift as jobs
    /// are added/removed across lanes) and runs the provider call inside the
    /// task stored in `runningTasks[jobID]`, which `cancel()` can target.
    private func runJob(jobID: TranscriptionJob.ID) async {
        guard let idx = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        let folder = jobs[idx].meetingFolder
        let expectedSpeakers = jobs[idx].expectedSpeakers
        guard let provider = providers[jobID] else {
            update(jobID: jobID) {
                $0.state = .failed(message: "Provider snapshot lost")
                $0.finishedAt = Date()
            }
            TranscriptionPendingMarker.delete(in: folder)
            return
        }

        update(jobID: jobID) {
            $0.startedAt = Date()
            $0.state = .running(stage: .loadingModels, overall: 0)
        }

        let micURL = folder.appendingPathComponent("mic.m4a")
        let outputURL = folder.appendingPathComponent("output.m4a")
        let languageCode = AppPreferences.shared.transcriptionLanguage.whisperCode
        let micGateIntervals = MicGateFile.read(from: folder)?.muted

        do {
            try await executeTranscription(
                jobID: jobID,
                folder: folder,
                micURL: micURL,
                outputURL: outputURL,
                languageCode: languageCode,
                micGateIntervals: micGateIntervals,
                expectedSpeakers: expectedSpeakers,
                provider: provider
            )
            markDone(jobID: jobID)
        } catch is CancellationError {
            markCancelled(jobID: jobID)
        } catch let urlErr as URLError where urlErr.code == .cancelled {
            markCancelled(jobID: jobID)
        } catch {
            markFailed(jobID: jobID, error: error)
        }

        runningTasks[jobID] = nil

        // Free the provider so multi-GB CoreML weights (local engine) don't
        // stay resident between jobs.
        let releasedProvider = providers.removeValue(forKey: jobID)
        if let releasedProvider {
            Task.detached { await releasedProvider.unloadModels() }
        }
    }
```

Note: the body that was wrapped in an inner `Task` is now the task body itself
(the task is created in `startExclusiveWorker`/`launchConcurrentJob`), so
`cancel()` on `runningTasks[jobID]` propagates `CancellationError` into the
`await executeTranscription` suspension point. `executeTranscription` (lines
~385-449) is unchanged.

- [ ] **Step 7: Run the lane tests to verify they pass**

Run:
```bash
pkill -9 -f "Meeting.app" 2>/dev/null; true
xcodebuild -project Meeting.xcodeproj -scheme Meeting -destination 'platform=macOS' \
  -only-testing:MeetingTests/TranscriptionQueueLaneTests test 2>&1 | tail -25
```
Expected: all 5 tests PASS (`test_concurrentCloudJobs_startInParallel` and `test_exclusiveJobs_startOneAtATime` now pass).

- [ ] **Step 8: Commit**

```bash
git add Meeting/Transcribe/TranscriptionQueue.swift MeetingTests/TranscriptionQueueLaneTests.swift
git commit -m "Two-lane transcription queue: concurrent batch, serial local"
```

---

## Task 5: Popover shows multiple running jobs

UI-only; this project does not unit-test SwiftUI views, so verification is the
full build in Task 6 plus a visual check.

**Files:**
- Modify: `Meeting/Transcribe/TranscriptionQueue.swift` (add a computed count near `runningJob`, line ~167)
- Modify: `Meeting/App/PopoverViews.swift` (`BackgroundJobsCard.body`, lines ~463-472)

- [ ] **Step 1: Add a running-count helper to the queue**

In `Meeting/Transcribe/TranscriptionQueue.swift`, after the `runningJob` computed property (ends line ~169), add:

```swift
    /// Number of jobs currently transcribing (any lane). With the concurrent
    /// batch lane this can exceed 1.
    var runningCount: Int {
        jobs.lazy.filter { if case .running = $0.state { return true }; return false }.count
    }
```

- [ ] **Step 2: Branch the card on running count**

In `Meeting/App/PopoverViews.swift`, replace `BackgroundJobsCard.body` (lines ~463-472):

```swift
    var body: some View {
        if let running = queue.runningJob {
            content(running: running)
        } else if queue.activeCount > 0 {
            // Edge case: nothing running but jobs queued (worker hop in
            // progress). Show a generic "queued" message so the indicator
            // doesn't disappear and reappear.
            queuedOnlyContent
        }
    }
```

with:

```swift
    var body: some View {
        if queue.runningCount > 1 {
            multipleRunningContent
        } else if let running = queue.runningJob {
            content(running: running)
        } else if queue.activeCount > 0 {
            // Edge case: nothing running but jobs queued (worker hop in
            // progress). Show a generic "queued" message so the indicator
            // doesn't disappear and reappear.
            queuedOnlyContent
        }
    }

    /// Several batch jobs polling concurrently — summarize rather than detail
    /// one. (Per-meeting progress is still visible on each Library row.)
    private var multipleRunningContent: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.brandAccent)
            Text("\(queue.runningCount) transcribing")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.textPrimary)
            if queue.queuedCount > 0 {
                Text("· \(queue.queuedCount) queued")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.textFaint)
            }
            Spacer()
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.regularMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.brandAccent.opacity(0.30), lineWidth: 0.5)
                }
        }
    }
```

- [ ] **Step 3: Build to verify it compiles**

Run:
```bash
xcodebuild -project Meeting.xcodeproj -scheme Meeting -configuration Debug \
  -destination 'platform=macOS' CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -15
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add Meeting/Transcribe/TranscriptionQueue.swift Meeting/App/PopoverViews.swift
git commit -m "Popover summarizes when multiple jobs transcribe concurrently"
```

---

## Task 6: Full regenerate, build, and test

**Files:** none (verification only)

- [ ] **Step 1: Regenerate the project**

Run: `xcodegen generate`
Expected: no errors; new files (`BatchUploadLimiter.swift`, the two test files) are in the project.

- [ ] **Step 2: Kill any stale running app (avoids test-runner hang)**

Run: `pkill -9 -f "Meeting.app" 2>/dev/null; true`

- [ ] **Step 3: Full build with Personal-Team signing**

Run:
```bash
xcodebuild -project Meeting.xcodeproj -scheme Meeting -configuration Debug \
  -destination 'platform=macOS' build 2>&1 | tail -15
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Run the full test suite**

Run:
```bash
xcodebuild -project Meeting.xcodeproj -scheme Meeting -configuration Debug \
  -destination 'platform=macOS' test 2>&1 | tail -30
```
Expected: `** TEST SUCCEEDED **` — all existing tests plus the new
`BatchUploadLimiterTests` and `TranscriptionQueueLaneTests` pass.

- [ ] **Step 5: Final commit (if regenerate changed the project file)**

```bash
git add Meeting.xcodeproj
git commit -m "Regenerate project for concurrent batch transcription" || echo "nothing to commit"
```

---

## Self-Review notes

- **Spec coverage:** ExecutionLane (Task 1) ✓; BatchUploadLimiter cap=2 + cancellation-aware acquire (Task 2) ✓; fresh-path acquire / release-before-poll / resume-path skip (Task 3) ✓; two-lane worker + `runningTasks` + cancel (Task 4) ✓; popover multi-running (Task 5) ✓; testing (Tasks 2 & 4) ✓.
- **Out-of-scope items** (sync-mode concurrency, Settings cap, rate-limit backoff) are intentionally not implemented, matching the spec.
- **Type consistency:** `executionLane` / `ExecutionLane` / `runningTasks` / `runningCount` / `releaseUploadSlot` / `BatchUploadLimiter.shared` used identically across tasks.
- **Manual check after merge:** record/queue two+ meetings with batch mode on and confirm both show "Transcribing" simultaneously and both batches appear PENDING on Google at the same time.
