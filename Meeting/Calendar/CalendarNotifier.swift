import Foundation
import UserNotifications
import Combine

/// Schedules pre-meeting reminders ("Q2 Roadmap Sync starts in 5 min")
/// based on the events the `CalendarStore` is publishing. Owned by
/// `AppState`. Also handles the "tap notification → open popover" flow
/// by forwarding through the shared notification center.
///
/// We don't bother batching — there are at most a handful of events in
/// the 8-hour upcoming window, and UNUserNotificationCenter handles
/// idempotent rescheduling well via stable identifiers.
@MainActor
final class CalendarNotifier: ObservableObject {
    /// Lead time for the reminder. Five minutes is the sweet spot — long
    /// enough to grab water and pull up the popover, short enough not to
    /// disrupt the prior block.
    static let leadTime: TimeInterval = 5 * 60
    /// We only schedule events that start within this many seconds from
    /// now. Anything farther out is reconsidered on the next refresh
    /// cycle (CalendarStore ticks once a minute).
    static let horizon: TimeInterval = 60 * 60

    /// Identifier prefix for our notifications so we can target them for
    /// cancellation without touching anyone else's pending requests.
    private static let identifierPrefix = "meeting.upcoming."

    private let center = UNUserNotificationCenter.current()
    private var cancellable: AnyCancellable?
    /// Last set of event IDs we scheduled — used to detect what to keep
    /// vs. cancel without round-tripping `getPendingNotificationRequests`.
    private var scheduledEventIDs: Set<String> = []

    init(calendar: CalendarStore) {
        // Re-evaluate the schedule whenever the store republishes.
        // No deinit cleanup: this notifier is owned by `AppState` and
        // lives for the full app lifetime — and `AnyCancellable` is not
        // Sendable, so it can't be cancelled from a nonisolated deinit
        // on a `@MainActor` class anyway. Process exit cancels the
        // subscription naturally.
        cancellable = calendar.$upcomingEvents
            .receive(on: RunLoop.main)
            .sink { [weak self] events in
                self?.reschedule(for: events)
            }
    }

    /// Ask for authorization. Safe to call repeatedly; the system caches
    /// the user's prior answer. No Info.plist entry is required for
    /// UNUserNotifications on macOS — the prompt comes from the
    /// authorization request itself.
    func requestAuthorizationIfNeeded() async {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        default:
            break
        }
    }

    private func reschedule(for events: [CalendarEvent]) {
        let now = Date()
        let cutoff = now.addingTimeInterval(Self.horizon)
        let relevant = events.filter { $0.startDate > now && $0.startDate <= cutoff }

        // Cancel any previously-scheduled notification whose event has
        // dropped out of the window or changed start time.
        let liveIDs = Set(relevant.map { $0.eventIdentifier })
        let stale = scheduledEventIDs.subtracting(liveIDs)
        if !stale.isEmpty {
            center.removePendingNotificationRequests(
                withIdentifiers: stale.map { Self.identifierPrefix + $0 }
            )
        }

        // Re-add every relevant request. UN dedupes on identifier, so
        // re-adding is cheap and corrects start-time drift if a meeting
        // was rescheduled.
        for event in relevant {
            schedule(event: event, now: now)
        }
        scheduledEventIDs = liveIDs
    }

    private func schedule(event: CalendarEvent, now: Date) {
        let fireDate = event.startDate.addingTimeInterval(-Self.leadTime)
        let interval = max(1, fireDate.timeIntervalSince(now))

        let content = UNMutableNotificationContent()
        content.title = event.title
        content.body = bodyText(for: event)
        content.sound = .default
        content.userInfo = [
            "kind": "meeting.upcoming",
            "eventId": event.eventIdentifier,
        ]

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        let request = UNNotificationRequest(
            identifier: Self.identifierPrefix + event.eventIdentifier,
            content: content,
            trigger: trigger
        )
        center.add(request) { error in
            if let error {
                NSLog("[Meeting/Calendar] notification add failed: %@",
                      String(describing: error))
            }
        }
    }

    private func bodyText(for event: CalendarEvent) -> String {
        let mins = Int((event.startDate.timeIntervalSinceNow / 60).rounded())
        let lead = max(1, mins)
        var parts = ["Starts in \(lead) min"]
        if let host = event.conferenceURL?.host {
            parts.append(host)
        }
        let count = event.totalAttendeeCount
        if count > 0 {
            parts.append(count == 1 ? "1 attendee" : "\(count) attendees")
        }
        return parts.joined(separator: " · ")
    }
}
