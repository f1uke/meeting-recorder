# Concurrent batch transcription — design

**Date:** 2026-06-04
**Status:** Approved, pending implementation plan

## Problem

`TranscriptionQueue` runs a single serial FIFO worker. A job holds the worker
for its entire lifetime — including the Gemini **batch poll loop**, which waits
on Google's batch queue for minutes up to a 24h SLA. While one batch job polls,
every other queued job sits idle and its batch is **never even submitted** to
Google.

This is correct for the local engine (WhisperKit + SpeakerKit is GPU/RAM-bound
and must run one job at a time) but wrong for batch mode: the actual compute
lives on Google's servers and runs in parallel there. When several meetings
queue back-to-back (observed 2026-06-04: three meetings, only one batch
in-flight), the user waits hours longer than necessary.

Observed today: `09-47`, `09-58`, and `iOS Innovation` all queued; only the
running job had a batch on Google's side. The other two had no batch submitted
at all.

## Goal

Batch jobs should not block each other. Submit each job's batch to Google as
soon as it is enqueued and poll all of them concurrently. Keep the local engine
strictly serial.

## Decisions (from brainstorming)

- **Concurrency model:** unlimited polling; cap only the upload phase. Upload
  (chunk audio + push ~95 files to Google) is the bandwidth/CPU-heavy local
  part; polling is cheap.
- **Local + batch coexistence:** separate lanes. A running local job does NOT
  block batch jobs — batch polling proceeds while local transcription runs,
  because they contend for different resources (Google servers vs. local GPU).
- **Approach:** two-lane queue + a shared upload limiter inside the provider
  (chosen over a protocol submit/poll split, which duplicates the
  resume-from-marker logic the provider already owns).

## Architecture

Five units, each independently testable.

### 1. `ExecutionLane` — provider capability

```swift
enum ExecutionLane: Sendable {
    case exclusive        // GPU/RAM-bound or rate-sensitive — at most one at a time
    case concurrentCloud  // server-side compute — safe to run many in parallel
}
```

Add to `TranscriptionProvider`:

```swift
var executionLane: ExecutionLane { get }
```

Default extension returns `.exclusive` so existing providers are unaffected.

- `GeminiProvider`: `useBatchAPI ? .concurrentCloud : .exclusive`
- `LocalProvider`, `OpenAIProvider`, Gemini sync mode: inherit `.exclusive`.

The queue reads the lane from the per-job provider snapshot
(`providers[jobID].executionLane`), captured at enqueue time.

### 2. `BatchUploadLimiter` — shared upload throttle

An `actor` singleton implementing an async counting semaphore.

```swift
actor BatchUploadLimiter {
    static let shared = BatchUploadLimiter(limit: 2)   // tunable constant
    func acquire() async throws   // suspends if at limit; cancellation-aware
    func release()
}
```

- `acquire()` honors `Task` cancellation: a cancelled job waiting for a slot
  throws `CancellationError` instead of holding a waiter.
- `release()` wakes the next waiter (FIFO).
- Implemented with a counter plus an ordered list of `CheckedContinuation`s.

Why a singleton: provider instances are created per-job by `providerFactory`,
so the limiter cannot live on a provider instance. All `GeminiProvider`
instances share `BatchUploadLimiter.shared`.

### 3. `GeminiProvider` integration

In `transcribeCombinedBatch`, the **fresh-submit path only** holds the limiter
across its upload+submit phase and releases it **before** polling — so the slot
is freed the moment the batch is handed to Google, not held for the whole poll.

```
try await BatchUploadLimiter.shared.acquire()
let batchName: String
do {
    // chunk prep (0..0.04) + chunk uploads (0.04..0.12) + JSONL + submitBatch
    batchName = try await submitBatch(inputFileName: jsonlFile.name)
} catch {
    BatchUploadLimiter.shared.release()   // release on failure mid-upload
    throw error
}
BatchUploadLimiter.shared.release()       // release on success, BEFORE pollBatch
// pollBatch(0.14..0.88) runs OUTSIDE the limiter — unbounded concurrency
```

Concretely: acquire before chunk prep (~current line 935), release right after
`submitBatch` returns (~current line 1090) and on any throw during upload,
before entering `pollBatch`. A function-scope `defer` is deliberately NOT used,
since that would hold the slot through the poll.

The **resume path** (`resumeBatchFromMarker`) does NOT acquire the limiter — it
performs no upload and goes straight to polling. This is what lets every
pending batch resume-poll concurrently after an app restart.

### 4. `TranscriptionQueue` — two-lane worker

Replace the single-worker state:

- Remove `runningJobTask` / `runningJobID` (single).
- Add `runningTasks: [TranscriptionJob.ID: Task<Void, Never>]` — cancel handles
  for jobs in any lane.
- Keep `workerTask` for the exclusive lane's serial loop.

**Enqueue dispatch** — after building the job and storing its provider:

```swift
switch provider.executionLane {
case .exclusive:       startExclusiveWorker()       // serial loop, as today
case .concurrentCloud: launchConcurrentJob(jobID)   // spawn Task immediately
}
```

**Exclusive lane** (`workerLoop`): unchanged shape, but the "next job" predicate
matches only queued jobs whose lane is `.exclusive`. Runs one at a time.

**Concurrent lane** (`launchConcurrentJob`): spawns the job's work in its own
`Task`, registers it in `runningTasks`, and removes it on completion. No serial
gate — concurrency is bounded only by `BatchUploadLimiter` during upload.

`runJob` / `executeTranscription` bodies are unchanged except for not assuming a
single running job: state transitions (`markDone` / `markFailed` /
`markCancelled`), provider unload, and marker handling stay as-is (all already
keyed by `jobID`).

**Cancel:** `runningTasks[jobID]?.cancel()` for any running job;
queued-exclusive jobs are still cancelled synchronously (removed from the list).

### 5. UI touch-ups (minor)

- `activeCount` / `queuedCount` already aggregate across all jobs — menu bar
  (`MenuBarLabel`) and `AppDelegate` need no change.
- `PopoverViews` (~line 464) uses `runningJob` (singular). Update so that when
  more than one job is running it summarizes (e.g. "3 transcribing") instead of
  detailing a single job.
- Library rows are already per-job; multiple "Transcribing" rows render
  correctly with no change.

## Data flow

```
enqueue(folder)
  └─ snapshot provider, write transcription_pending.json
  └─ lane == .concurrentCloud?
       ├─ yes → launchConcurrentJob → Task → transcribeBatch
       │         └─ fresh: acquire upload slot → prep+upload+submit → release → poll(unbounded)
       │         └─ resume: (no slot) → poll(unbounded)
       └─ no  → startExclusiveWorker → serial loop → runJob (one at a time)
```

Restart: `scanAndEnqueueOrphans` enqueues each orphan; batch ones launch
concurrently and resume-poll via their existing `gemini_batch_pending.json`
markers, with no upload and no limiter contention.

## Error handling / edge cases

- Upload slot is always released (acquire/release scoped so a throw or
  cancellation inside upload still releases).
- N queued batch jobs → N Tasks spawned immediately; at most 2 upload at once,
  the rest suspend at `acquire()` (suspended Tasks are cheap); polling is
  unbounded once submitted.
- Cancelling a job parked at `acquire()` throws `CancellationError`, freeing the
  slot for the next waiter.
- Per-job provider unload after completion is unchanged.

## Testing

- **`BatchUploadLimiter`**: `limit` enforced (first N `acquire()`s proceed, the
  N+1th suspends until a `release()`); `acquire()` respects task cancellation.
- **Queue lanes**: with a `FakeProvider` exposing a configurable
  `executionLane` and a body gated by a continuation (no network):
  - 3 `.concurrentCloud` jobs all reach "started" without waiting for each other.
  - 2 `.exclusive` jobs: the second does not start until the first finishes.
- **Regression**: default-lane (`.exclusive`) providers remain strictly serial,
  matching current behavior.

## Out of scope

- Making Gemini **sync** mode concurrent (it stays `.exclusive` for now; could
  join the cloud lane later under its own rate-limit handling).
- Configurable upload cap in Settings (hardcoded constant for now).
- Per-provider rate-limit backoff coordination.
