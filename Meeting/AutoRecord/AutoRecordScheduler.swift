import Foundation
import Combine

/// Watches a `CalendarEventSource`, identifies the next event that's
/// eligible and within the arm horizon, and exposes a `@Published`
/// `AutoRecordState` for the UI. Countdown ticking and firing land in
/// a follow-up task.
@MainActor
final class AutoRecordScheduler: ObservableObject {

    /// Horizon, in seconds, beyond which we don't even arm. Keeps the
    /// scheduler in `.idle` for the vast majority of the day. Events
    /// inside this window get a `Task.sleep` scheduled to flip to
    /// `.countingDown`.
    static let armHorizon: TimeInterval = 60
    /// Tolerance when deciding whether a new `reevaluate()` should re-arm for
    /// the same event. Prevents churn when the calendar source re-publishes
    /// with minor date drift (sub-30s start-time shifts keep the existing
    /// armed state).
    static let rearmTolerance: TimeInterval = 30

    @Published private(set) var state: AutoRecordState = .idle

    private let eventSource: CalendarEventSource
    private let clock: AutoRecordClock
    private let resolver: AutoRecordSourceResolving
    private var prefsProvider: () -> AutoRecordEligibilityPrefs
    private let countdownSecondsProvider: () -> Int
    private let sourceFallbackProvider: () -> AutoRecordSourceFallback
    private let isAlreadyRecording: () -> Bool
    private let hasRequiredPermissions: () -> AutoRecordSuppressionReason?
    private let onStart: (CaptureSource, CalendarEvent) async -> Void
    private let onSkip: (CalendarEvent, AutoRecordSuppressionReason) -> Void

    private var cancellables: Set<AnyCancellable> = []
    private var armedTask: Task<Void, Never>?
    private var suppressedThisSession: Set<String> = []

    /// Cached snapshots updated whenever the source publishes. Used by
    /// `collectPool()` so we avoid cross-module type-casting in tests.
    private var latestUpcoming: [CalendarEvent] = []
    private var latestCurrent: [CalendarEvent] = []

    init(
        eventSource: CalendarEventSource,
        clock: AutoRecordClock,
        resolver: AutoRecordSourceResolving,
        prefsProvider: @escaping () -> AutoRecordEligibilityPrefs,
        countdownSecondsProvider: @escaping () -> Int,
        sourceFallbackProvider: @escaping () -> AutoRecordSourceFallback,
        isAlreadyRecording: @escaping () -> Bool,
        hasRequiredPermissions: @escaping () -> AutoRecordSuppressionReason?,
        onStart: @escaping (CaptureSource, CalendarEvent) async -> Void,
        onSkip: @escaping (CalendarEvent, AutoRecordSuppressionReason) -> Void
    ) {
        self.eventSource = eventSource
        self.clock = clock
        self.resolver = resolver
        self.prefsProvider = prefsProvider
        self.countdownSecondsProvider = countdownSecondsProvider
        self.sourceFallbackProvider = sourceFallbackProvider
        self.isAlreadyRecording = isAlreadyRecording
        self.hasRequiredPermissions = hasRequiredPermissions
        self.onStart = onStart
        self.onSkip = onSkip

        eventSource.upcomingEventsPublisher
            .sink { [weak self] events in
                self?.latestUpcoming = events
                self?.reevaluate()
            }
            .store(in: &cancellables)

        eventSource.currentEventsPublisher
            .sink { [weak self] events in
                self?.latestCurrent = events
                self?.reevaluate()
            }
            .store(in: &cancellables)
    }

    /// Public for tests and for AppState to call when prefs change.
    func reevaluate() {
        let prefs = prefsProvider()
        let now = clock.now()
        let pool = collectPool()
        let next = pool.first { evt in
            AutoRecordEligibility.eligible(
                event: evt,
                prefs: prefs,
                suppressedIDs: suppressedThisSession,
                now: now
            )
        }
        guard let next else {
            disarm()
            return
        }
        let secondsUntilStart = next.startDate.timeIntervalSince(now)
        if secondsUntilStart > Self.armHorizon {
            disarm()
            return
        }
        // Same event still armed → keep going.
        if case let .armed(currentEvt, currentFireAt) = state,
           currentEvt.eventIdentifier == next.eventIdentifier,
           abs(currentFireAt.timeIntervalSince(next.startDate)) <= Self.rearmTolerance {
            return
        }
        arm(event: next)
    }

    private func collectPool() -> [CalendarEvent] {
        (latestCurrent + latestUpcoming).sorted { $0.startDate < $1.startDate }
    }

    private func arm(event: CalendarEvent) {
        armedTask?.cancel()
        let fireAt = event.startDate
        state = .armed(event: event, fireAt: fireAt)
        // Countdown wakeup task is added in a later task; for now we just
        // sit in `.armed`.
    }

    private func disarm() {
        armedTask?.cancel()
        armedTask = nil
        if state != .idle { state = .idle }
    }

    // MARK: - Test seam

    /// Test-only: replace the prefsProvider after init so tests can flip
    /// the master toggle by mutating their own host's provider and calling
    /// `reevaluate()`. Production code should never call this.
    func testOnly_overridePrefsProvider(_ provider: @escaping () -> AutoRecordEligibilityPrefs) {
        self.prefsProvider = provider
    }
}

