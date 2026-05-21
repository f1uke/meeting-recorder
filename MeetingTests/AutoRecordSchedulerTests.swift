import XCTest
import Combine
import ScreenCaptureKit
@testable import Meeting

@MainActor
final class AutoRecordSchedulerTests: XCTestCase {

    func test_idle_whenNoEligibleEvents() async throws {
        let source = FakeEventSource()
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let resolver = StubResolver()
        let host = SchedulerTestHost(source: source, clock: clock, resolver: resolver)

        // No events published → stays idle.
        await Task.yield()
        XCTAssertEqual(host.scheduler.state, .idle)
    }

    func test_armedWhenEligibleEventInUpcoming() async throws {
        let source = FakeEventSource()
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let resolver = StubResolver()
        let host = SchedulerTestHost(source: source, clock: clock, resolver: resolver)

        let evt = host.makeEvent(id: "e1", startsIn: 45)
        source.upcoming = [evt]
        await Task.yield()
        await Task.yield() // let the sink fire

        if case let .armed(armedEvt, fireAt) = host.scheduler.state {
            XCTAssertEqual(armedEvt.eventIdentifier, "e1")
            XCTAssertEqual(fireAt, evt.startDate)
        } else {
            XCTFail("Expected .armed, got \(host.scheduler.state)")
        }
    }

    func test_remainsIdleWhenEventFartherThanArmHorizon() async throws {
        let source = FakeEventSource()
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let host = SchedulerTestHost(source: source, clock: clock, resolver: StubResolver())

        // Event 5 minutes out — beyond the 60s arm horizon.
        let evt = host.makeEvent(id: "e1", startsIn: 5 * 60)
        source.upcoming = [evt]
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(host.scheduler.state, .idle)
    }

    func test_disarmedWhenEventRemovedFromUpcoming() async throws {
        let source = FakeEventSource()
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let host = SchedulerTestHost(source: source, clock: clock, resolver: StubResolver())

        let evt = host.makeEvent(id: "e1", startsIn: 30)
        source.upcoming = [evt]
        await Task.yield(); await Task.yield()
        XCTAssertNotEqual(host.scheduler.state, .idle)

        source.upcoming = []
        await Task.yield(); await Task.yield()
        XCTAssertEqual(host.scheduler.state, .idle)
    }

    func test_disarmedWhenMasterToggleFlippedOff() async throws {
        let source = FakeEventSource()
        let clock = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let host = SchedulerTestHost(source: source, clock: clock, resolver: StubResolver())

        let evt = host.makeEvent(id: "e1", startsIn: 30)
        source.upcoming = [evt]
        await Task.yield(); await Task.yield()
        XCTAssertNotEqual(host.scheduler.state, .idle)

        host.prefsProvider = { AutoRecordEligibilityPrefs(masterEnabled: false, enabledCalendarIDs: ["cal-work"]) }
        host.scheduler.reevaluate()
        await Task.yield(); await Task.yield()
        XCTAssertEqual(host.scheduler.state, .idle)
    }

    func test_transitionsToCountingDownAtFireMinusCountdown() async throws {
        let source = FakeEventSource()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = TestClock(start)
        let captureSource = try await realDisplaySource()
        let resolver = StubResolver(result: .source(captureSource, subtitle: "Zoom · 4 attendees"))
        let host = SchedulerTestHost(source: source, clock: clock, resolver: resolver)

        let evt = host.makeEvent(id: "e1", startsIn: 30)
        source.upcoming = [evt]
        await yieldRunloop()

        clock.advance(to: start.addingTimeInterval(25))
        await yieldRunloop()

        if case let .countingDown(_, subtitle, remaining) = host.scheduler.state {
            XCTAssertEqual(subtitle, "Zoom · 4 attendees")
            XCTAssertEqual(remaining, 5)
        } else {
            XCTFail("Expected .countingDown, got \(host.scheduler.state)")
        }
    }

    func test_countdownTicksDownAndFires() async throws {
        let source = FakeEventSource()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = TestClock(start)
        let captureSource = try await realDisplaySource()
        let resolver = StubResolver(result: .source(captureSource, subtitle: "s"))
        let host = SchedulerTestHost(source: source, clock: clock, resolver: resolver)
        var fired: CalendarEvent?
        host.scheduler.setOnStart { _, evt in fired = evt }

        let evt = host.makeEvent(id: "e1", startsIn: 6)
        source.upcoming = [evt]
        await yieldRunloop()
        clock.advance(to: start.addingTimeInterval(1)) // fireAt-5 = +1
        await yieldRunloop()

        for s in 2...6 {
            clock.advance(to: start.addingTimeInterval(TimeInterval(s)))
            await yieldRunloop()
        }
        XCTAssertEqual(fired?.eventIdentifier, "e1")
        XCTAssertEqual(host.scheduler.state, .idle)
    }

    func test_userCancelMovesToIdleAndSuppresses() async throws {
        let source = FakeEventSource()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = TestClock(start)
        let captureSource = try await realDisplaySource()
        let resolver = StubResolver(result: .source(captureSource, subtitle: "s"))
        let host = SchedulerTestHost(source: source, clock: clock, resolver: resolver)
        var skipped: (CalendarEvent, AutoRecordSuppressionReason)?
        host.scheduler.setOnSkip { evt, reason in skipped = (evt, reason) }

        let evt = host.makeEvent(id: "e1", startsIn: 6)
        source.upcoming = [evt]
        await yieldRunloop()
        clock.advance(to: start.addingTimeInterval(1))
        await yieldRunloop()
        XCTAssertNotEqual(host.scheduler.state, .idle)

        host.scheduler.cancelCurrentCountdown()
        await yieldRunloop()
        XCTAssertEqual(host.scheduler.state, .idle)
        XCTAssertEqual(skipped?.0.eventIdentifier, "e1")
        XCTAssertEqual(skipped?.1, .userCancelledThisOccurrence)

        // Same event re-published → does NOT re-arm.
        source.upcoming = [evt]
        await yieldRunloop()
        XCTAssertEqual(host.scheduler.state, .idle)
    }

    func test_startNowFiresImmediately() async throws {
        let source = FakeEventSource()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = TestClock(start)
        let captureSource = try await realDisplaySource()
        let resolver = StubResolver(result: .source(captureSource, subtitle: "s"))
        let host = SchedulerTestHost(source: source, clock: clock, resolver: resolver)
        var fired = false
        host.scheduler.setOnStart { _, _ in fired = true }

        let evt = host.makeEvent(id: "e1", startsIn: 6)
        source.upcoming = [evt]
        await yieldRunloop()
        clock.advance(to: start.addingTimeInterval(1))
        await yieldRunloop()

        host.scheduler.startNow()
        await yieldRunloop()
        XCTAssertTrue(fired)
        XCTAssertEqual(host.scheduler.state, .idle)
    }

    func test_skipsWhenAlreadyRecording() async throws {
        let source = FakeEventSource()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = TestClock(start)
        let captureSource = try await realDisplaySource()
        let resolver = StubResolver(result: .source(captureSource, subtitle: "s"))
        let host = SchedulerTestHost(source: source, clock: clock, resolver: resolver)
        var skipped: AutoRecordSuppressionReason?
        host.scheduler.setOnSkip { _, reason in skipped = reason }
        host.scheduler.setIsAlreadyRecording { true }

        let evt = host.makeEvent(id: "e1", startsIn: 6)
        source.upcoming = [evt]
        await yieldRunloop()
        clock.advance(to: start.addingTimeInterval(1))
        await yieldRunloop()

        XCTAssertEqual(host.scheduler.state, .idle)
        XCTAssertEqual(skipped, .alreadyRecording)
    }

    func test_skipsWhenSourceResolverSkips() async throws {
        let source = FakeEventSource()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = TestClock(start)
        let resolver = StubResolver(result: .skip(reason: "no window"))
        let host = SchedulerTestHost(source: source, clock: clock, resolver: resolver)
        var skipped: AutoRecordSuppressionReason?
        host.scheduler.setOnSkip { _, reason in skipped = reason }

        let evt = host.makeEvent(id: "e1", startsIn: 6)
        source.upcoming = [evt]
        await yieldRunloop()
        clock.advance(to: start.addingTimeInterval(1))
        await yieldRunloop()

        XCTAssertEqual(host.scheduler.state, .idle)
        XCTAssertEqual(skipped, .sourceUnavailableAndSkipFallback)
    }

    func test_doesNotRetroactivelyTriggerAfterSleep() async throws {
        let source = FakeEventSource()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = TestClock(start)
        let host = SchedulerTestHost(source: source, clock: clock, resolver: StubResolver())
        var skipped: AutoRecordSuppressionReason?
        host.scheduler.setOnSkip { _, reason in skipped = reason }

        let evt = host.makeEvent(id: "e1", startsIn: 30)
        source.upcoming = [evt]
        await yieldRunloop()
        // Simulate sleep past fireAt — jump well past startDate.
        clock.advance(to: start.addingTimeInterval(120))
        await yieldRunloop()

        XCTAssertEqual(host.scheduler.state, .idle)
        XCTAssertEqual(skipped, .eventStartedWhileMacAsleep)
    }

    private func yieldRunloop() async {
        for _ in 0..<8 { await Task.yield() }
    }

    /// Returns a real `CaptureSource` from `SCShareableContent`, or skips
    /// the test if Screen Recording isn't permissioned in the runner.
    @MainActor
    private func realDisplaySource() async throws -> CaptureSource {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                true, onScreenWindowsOnly: true)
        } catch {
            throw XCTSkip("Screen Recording permission unavailable: \(error)")
        }
        try XCTSkipIf(content.displays.isEmpty,
                      "No displays found via SCShareableContent")
        return .display(content.displays[0])
    }
}

// MARK: - Test infrastructure

@MainActor
final class FakeEventSource: CalendarEventSource {
    @Published var current: [CalendarEvent] = []
    @Published var upcoming: [CalendarEvent] = []
    var currentEventsPublisher: Published<[CalendarEvent]>.Publisher { $current }
    var upcomingEventsPublisher: Published<[CalendarEvent]>.Publisher { $upcoming }
}

@MainActor
final class TestClock: AutoRecordClock {
    private var current: Date
    private var pending: [(Date, CheckedContinuation<Void, Error>)] = []
    init(_ initial: Date) { self.current = initial }
    func now() -> Date { current }
    func sleep(until deadline: Date) async throws {
        if deadline <= current { return }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            pending.append((deadline, cont))
        }
    }
    func advance(to: Date) {
        current = to
        let fire = pending.filter { $0.0 <= to }
        pending.removeAll { $0.0 <= to }
        for (_, cont) in fire { cont.resume() }
    }
}

struct StubResolver: AutoRecordSourceResolving {
    var result: AutoRecordResolveResult = .skip(reason: "stub")
    func resolve(event: CalendarEvent,
                 fallback: AutoRecordSourceFallback) async -> AutoRecordResolveResult {
        result
    }
}

@MainActor
final class SchedulerTestHost {
    let source: FakeEventSource
    let clock: TestClock
    let resolver: StubResolver
    let scheduler: AutoRecordScheduler
    var prefsProvider: () -> AutoRecordEligibilityPrefs = {
        AutoRecordEligibilityPrefs(masterEnabled: true, enabledCalendarIDs: ["cal-work"])
    }

    init(source: FakeEventSource, clock: TestClock, resolver: StubResolver) {
        self.source = source
        self.clock = clock
        self.resolver = resolver
        let initialPrefs: () -> AutoRecordEligibilityPrefs = {
            AutoRecordEligibilityPrefs(masterEnabled: true, enabledCalendarIDs: ["cal-work"])
        }
        self.scheduler = AutoRecordScheduler(
            eventSource: source,
            clock: clock,
            resolver: resolver,
            prefsProvider: initialPrefs,
            countdownSecondsProvider: { 5 },
            sourceFallbackProvider: { .display },
            isAlreadyRecording: { false },
            hasRequiredPermissions: { nil },
            onStart: { _, _ in },
            onSkip: { _, _ in }
        )
        // Allow tests to mutate prefs via host.prefsProvider; the scheduler
        // re-reads via the closure that already references our `prefsProvider`.
        self.scheduler.testOnly_overridePrefsProvider { [weak self] in
            self?.prefsProvider() ?? initialPrefs()
        }
    }

    func makeEvent(id: String, startsIn: TimeInterval) -> CalendarEvent {
        CalendarEvent(
            eventIdentifier: id,
            externalIdentifier: nil,
            title: "Test \(id)",
            startDate: clock.now().addingTimeInterval(startsIn),
            endDate: clock.now().addingTimeInterval(startsIn + 30 * 60),
            location: nil,
            conferenceURL: URL(string: "https://zoom.us/j/1"),
            calendarName: "Work",
            calendarIdentifier: "cal-work",
            organizer: nil,
            attendees: [],
            openInCalendarURL: nil
        )
    }
}
