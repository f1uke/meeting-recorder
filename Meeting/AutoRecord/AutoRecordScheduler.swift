import Foundation
import Combine

/// Watches a `CalendarEventSource`, identifies the next event that's
/// eligible and within the arm horizon, and drives the
/// `.idle → .armed → .countingDown → fire / skip` state machine.
@MainActor
final class AutoRecordScheduler: ObservableObject {

    /// Horizon, in seconds, beyond which we don't even arm. Keeps the
    /// scheduler in `.idle` for the vast majority of the day.
    static let armHorizon: TimeInterval = 60
    /// Tolerance when deciding whether a new `reevaluate()` should re-arm for
    /// the same event. Prevents churn when the calendar source re-publishes
    /// with minor date drift.
    static let rearmTolerance: TimeInterval = 30

    @Published private(set) var state: AutoRecordState = .idle

    private let eventSource: CalendarEventSource
    private let clock: AutoRecordClock
    private let resolver: AutoRecordSourceResolving
    private var prefsProvider: () -> AutoRecordEligibilityPrefs
    private let countdownSecondsProvider: () -> Int
    private let sourceFallbackProvider: () -> AutoRecordSourceFallback
    private let isAlreadyRecordingDefault: () -> Bool
    private let hasRequiredPermissions: () -> AutoRecordSuppressionReason?
    private let onStart: (CaptureSource, CalendarEvent) async -> Void
    private let onSkip: (CalendarEvent, AutoRecordSuppressionReason) -> Void

    // Test-only overrides.
    fileprivate var onStartOverride: ((CaptureSource, CalendarEvent) async -> Void)?
    fileprivate var onSkipOverride: ((CalendarEvent, AutoRecordSuppressionReason) -> Void)?
    fileprivate var isAlreadyRecordingOverride: (() -> Bool)?

    private var cancellables: Set<AnyCancellable> = []
    private var armedTask: Task<Void, Never>?
    private var countdownTask: Task<Void, Never>?
    private var pendingSource: CaptureSource?
    private var suppressedThisSession: Set<String> = []

    /// Cached snapshots updated whenever the source publishes.
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
        self.isAlreadyRecordingDefault = isAlreadyRecording
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

    // MARK: - Public

    /// Public for tests and for AppState to call when prefs change.
    func reevaluate() {
        let prefs = prefsProvider()
        let now = clock.now()
        let pool = (latestCurrent + latestUpcoming).sorted { $0.startDate < $1.startDate }
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
        // Already counting down on this event — don't restart.
        if case let .countingDown(currentEvt, _, _) = state,
           currentEvt.eventIdentifier == next.eventIdentifier {
            return
        }
        arm(event: next)
    }

    /// Cancel the active countdown. Panel "Dismiss" button calls this.
    /// Suppresses the event for this session.
    func cancelCurrentCountdown() {
        guard case let .countingDown(evt, _, _) = state else { return }
        countdownTask?.cancel()
        countdownTask = nil
        pendingSource = nil
        suppressedThisSession.insert(evt.eventIdentifier)
        skip(evt, reason: .userCancelledThisOccurrence)
        state = .idle
    }

    /// Fire immediately, skipping the remaining countdown ticks.
    /// Panel "Start now" button calls this.
    func startNow() {
        guard case let .countingDown(evt, _, _) = state,
              let source = pendingSource else { return }
        countdownTask?.cancel()
        countdownTask = nil
        pendingSource = nil
        state = .idle
        let onStart = onStartOverride ?? self.onStart
        Task {
            await onStart(source, evt)
        }
    }

    // MARK: - Private state machine

    private func arm(event: CalendarEvent) {
        armedTask?.cancel()
        countdownTask?.cancel()
        pendingSource = nil
        let fireAt = event.startDate
        state = .armed(event: event, fireAt: fireAt)

        let countdownStart = fireAt.addingTimeInterval(-TimeInterval(countdownSecondsProvider()))
        armedTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.clock.sleep(until: countdownStart)
            } catch {
                return // cancelled
            }
            if Task.isCancelled { return }
            await self.beginCountdown(for: event)
        }
    }

    private func disarm() {
        armedTask?.cancel(); armedTask = nil
        countdownTask?.cancel(); countdownTask = nil
        pendingSource = nil
        if state != .idle { state = .idle }
    }

    private func beginCountdown(for event: CalendarEvent) async {
        let prefs = prefsProvider()
        // Calendar may have changed during sleep.
        guard AutoRecordEligibility.eligible(
            event: event,
            prefs: prefs,
            suppressedIDs: suppressedThisSession,
            now: clock.now()
        ) else {
            state = .idle
            return
        }
        // Retroactive-trigger guard: never auto-fire for an event whose
        // start time has already passed. Happens when Mac slept through
        // the original fireAt.
        if clock.now() > event.startDate {
            skip(event, reason: .eventStartedWhileMacAsleep)
            suppressedThisSession.insert(event.eventIdentifier)
            state = .idle
            return
        }
        if (isAlreadyRecordingOverride ?? isAlreadyRecordingDefault)() {
            skip(event, reason: .alreadyRecording)
            suppressedThisSession.insert(event.eventIdentifier)
            state = .idle
            return
        }
        if let missing = hasRequiredPermissions() {
            skip(event, reason: missing)
            suppressedThisSession.insert(event.eventIdentifier)
            state = .idle
            return
        }

        let result = await resolver.resolve(event: event, fallback: sourceFallbackProvider())
        switch result {
        case .skip:
            skip(event, reason: .sourceUnavailableAndSkipFallback)
            suppressedThisSession.insert(event.eventIdentifier)
            state = .idle
            return
        case let .source(source, subtitle):
            pendingSource = source
            state = .countingDown(
                event: event,
                subtitle: subtitle,
                remaining: countdownSecondsProvider()
            )
            runCountdownTicks(for: event, source: source)
        }
    }

    private func runCountdownTicks(for event: CalendarEvent, source: CaptureSource) {
        countdownTask?.cancel()
        countdownTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let nextTick = clock.now().addingTimeInterval(1)
                do {
                    try await clock.sleep(until: nextTick)
                } catch { return }
                guard case let .countingDown(evt, sub, remaining) = state,
                      evt.eventIdentifier == event.eventIdentifier else { return }
                if remaining <= 1 {
                    await fire(source: source, event: event)
                    return
                }
                state = .countingDown(event: evt, subtitle: sub, remaining: remaining - 1)
            }
        }
    }

    private func fire(source: CaptureSource, event: CalendarEvent) async {
        pendingSource = nil
        state = .idle
        await (onStartOverride ?? onStart)(source, event)
    }

    private func skip(_ event: CalendarEvent, reason: AutoRecordSuppressionReason) {
        (onSkipOverride ?? onSkip)(event, reason)
    }

    // MARK: - Test seams

    /// Test-only: replace prefsProvider after init so tests can flip
    /// the master toggle by mutating their own host's provider and calling
    /// `reevaluate()`. Production code should never call this.
    func testOnly_overridePrefsProvider(_ provider: @escaping () -> AutoRecordEligibilityPrefs) {
        self.prefsProvider = provider
    }

    func setOnStart(_ f: @escaping (CaptureSource, CalendarEvent) async -> Void) {
        onStartOverride = f
    }
    func setOnSkip(_ f: @escaping (CalendarEvent, AutoRecordSuppressionReason) -> Void) {
        onSkipOverride = f
    }
    func setIsAlreadyRecording(_ f: @escaping () -> Bool) {
        isAlreadyRecordingOverride = f
    }
}
