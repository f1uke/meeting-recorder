import Foundation

/// Abstraction over `Date()` + `Task.sleep` so `AutoRecordScheduler` is
/// unit-testable with a fake clock that can be advanced synchronously.
/// `@MainActor` because the scheduler is `@MainActor`; the production
/// `SystemClock` doesn't actually need main isolation, but constraining
/// the protocol keeps the test clock simple.
@MainActor
protocol AutoRecordClock: AnyObject {
    func now() -> Date
    /// Sleeps until `deadline`. Returns immediately if `deadline` has
    /// already passed. Honors task cancellation.
    func sleep(until deadline: Date) async throws
}

/// Production clock. Trivial wrapper around `Date()` and `Task.sleep`.
@MainActor
final class SystemClock: AutoRecordClock {
    func now() -> Date { Date() }

    func sleep(until deadline: Date) async throws {
        let delay = deadline.timeIntervalSinceNow
        guard delay > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
    }
}
