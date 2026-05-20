import XCTest
import Combine
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
