import Foundation
import EventKit
import Combine
import os

/// MainActor wrapper around `EKEventStore`. Responsible for:
/// - Asking for and tracking calendar permission.
/// - Materialising the small slice of events the UI cares about
///   (anything overlapping ±15 min around "now", plus the next 8 hours)
///   into Sendable `CalendarEvent` values.
/// - Re-fetching whenever EventKit publishes `EKEventStoreChanged`, when
///   the wall-clock minute ticks over (events become "now"), and when
///   asked explicitly by the popover/AppState.
///
/// Intentionally not touching EventKit on background threads — the
/// `EKEventStore` API is documented as thread-safe but we keep all calls
/// on the main actor since the volume is tiny (events are pre-filtered
/// to a narrow window) and it dodges the usual Sendable ceremony.
@MainActor
final class CalendarStore: ObservableObject {
    /// Authorization state mirrored into a Sendable enum so the UI can
    /// switch on it without importing EventKit everywhere.
    enum Authorization: Equatable, Sendable {
        case notDetermined
        case denied
        case authorized
        /// macOS 14+ "write-only" — we treat this as denied for our
        /// purposes since we need to read events.
        case writeOnly
    }

    @Published private(set) var authorization: Authorization
    /// Events overlapping `now` (i.e. happening right at this moment).
    /// Usually 0 or 1, occasionally 2 when meetings overlap.
    @Published private(set) var currentEvents: [CalendarEvent] = []
    /// Events starting within the next 8 hours, excluding the ones
    /// already in `currentEvents`. Sorted by start ascending.
    @Published private(set) var upcomingEvents: [CalendarEvent] = []

    private let store = EKEventStore()
    private var refreshTask: Task<Void, Never>?
    private var changeObserverTask: Task<Void, Never>?
    private var meEmailsObserver: AnyCancellable?

    /// Override hook for tests that want to substitute the "current user
    /// email" used to mark attendees as `isMe`. nil = read from
    /// `AppPreferences.shared.myEmails`.
    var meEmailsOverride: Set<String>?

    init() {
        self.authorization = Self.mapAuth(EKEventStore.authorizationStatus(for: .event))

        // Re-snapshot when the user edits their "my emails" list, so
        // attendee.isMe flips immediately for newly fetched events.
        meEmailsObserver = AppPreferences.shared.$myEmails
            .dropFirst()
            .sink { [weak self] _ in
                self?.refresh()
            }

        // Watch EKEventStoreChanged via the modern AsyncStream API rather
        // than addObserver(forName:) — the block-based observer captures
        // a non-Sendable token that we'd then have to clean up from
        // deinit, which Swift 6 strict concurrency disallows for
        // @MainActor-isolated classes. Task cancellation tears the
        // for-await loop down cleanly.
        changeObserverTask = Task { [weak self] in
            let stream = NotificationCenter.default.notifications(
                named: .EKEventStoreChanged,
                object: nil
            )
            for await _ in stream {
                if Task.isCancelled { break }
                await MainActor.run { self?.refresh() }
            }
        }

        // Kick off the periodic refresh loop. Sleeps to the next minute
        // boundary so events transition from upcoming → current in sync
        // with the wall clock.
        refreshTask = Task { [weak self] in
            await self?.runRefreshLoop()
        }
    }

    deinit {
        // Both Task<Void, Never> values are Sendable, so cancel-from-
        // nonisolated-deinit is allowed. The for-await loops inside each
        // task observe the cancellation and exit promptly.
        refreshTask?.cancel()
        changeObserverTask?.cancel()
    }

    // MARK: - Permission

    /// Request access. macOS 14+ uses the new split API; older falls back
    /// to the deprecated requestAccess(to:).
    func requestAccess() async {
        let granted: Bool
        if #available(macOS 14.0, *) {
            granted = (try? await store.requestFullAccessToEvents()) ?? false
        } else {
            granted = await withCheckedContinuation { cont in
                store.requestAccess(to: .event) { ok, _ in
                    cont.resume(returning: ok)
                }
            }
        }
        authorization = Self.mapAuth(EKEventStore.authorizationStatus(for: .event))
        if granted { refresh() }
    }

    // MARK: - Refresh

    /// Re-query EventKit and republish current/upcoming. Also re-reads
    /// `EKEventStore.authorizationStatus` so the published
    /// `authorization` value stays in sync with TCC — important because
    /// the user can grant access via either our own `requestAccess()`
    /// path *or* the shared `PermissionManager.request(.calendar)` path,
    /// and the latter uses its own `EKEventStore` instance.
    func refresh() {
        authorization = Self.mapAuth(EKEventStore.authorizationStatus(for: .event))
        guard authorization == .authorized else {
            currentEvents = []
            upcomingEvents = []
            return
        }
        let now = Date()
        // ± 15 minutes around now to catch events that just ended /
        // starting in a few minutes; plus everything in the next 8 hours
        // for the upcoming list.
        let windowStart = now.addingTimeInterval(-15 * 60)
        let windowEnd = now.addingTimeInterval(8 * 60 * 60)

        let calendars = store.calendars(for: .event)
        let predicate = store.predicateForEvents(
            withStart: windowStart, end: windowEnd, calendars: calendars
        )
        let ekEvents = store.events(matching: predicate)
        let mapped = ekEvents.map { Self.snapshot(from: $0, meEmails: meEmails()) }

        // An "all-day" event is typically a holiday or OOO marker, not
        // something the user wants to record — exclude.
        let filtered = mapped.filter { !($0.endDate.timeIntervalSince($0.startDate) >= 23 * 60 * 60) }

        let current = filtered.filter { $0.startDate <= now && now <= $0.endDate }
            .sorted { $0.startDate < $1.startDate }
        let upcoming = filtered.filter { $0.startDate > now }
            .sorted { $0.startDate < $1.startDate }

        self.currentEvents = current
        self.upcomingEvents = upcoming
    }

    private func runRefreshLoop() async {
        // Initial fetch, then sleep to top-of-minute and repeat.
        refresh()
        while !Task.isCancelled {
            let now = Date()
            let nextMinute = Calendar.current.nextDate(
                after: now, matching: DateComponents(second: 0),
                matchingPolicy: .nextTime
            ) ?? now.addingTimeInterval(60)
            let delay = max(1, nextMinute.timeIntervalSince(now))
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if Task.isCancelled { break }
            refresh()
        }
    }

    // MARK: - Querying

    /// All events the popover wants to surface in the "Now" card,
    /// in priority order (current first, then upcoming).
    var relevantEvents: [CalendarEvent] {
        currentEvents + upcomingEvents
    }

    // MARK: - EKEvent → CalendarEvent

    /// Best-effort conference URL extraction. EventKit gives us the
    /// dedicated `EKEvent.url` (Zoom/Meet/Teams set this), and many
    /// invites also stash the join link in notes or location. Ranks
    /// `event.url` highest, then any URL found in notes/location.
    private static func conferenceURL(from event: EKEvent) -> URL? {
        if let url = event.url { return url }
        let haystacks = [event.notes, event.location].compactMap { $0 }
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        for text in haystacks {
            let range = NSRange(text.startIndex..., in: text)
            guard let matches = detector?.matches(in: text, range: range) else { continue }
            for match in matches {
                if let url = match.url, isLikelyConferenceURL(url) {
                    return url
                }
            }
            // Fall back to the first URL even if it doesn't look like a
            // conferencing host — better than nothing.
            if let url = matches.first?.url { return url }
        }
        return nil
    }

    /// Heuristic: hostnames we know are conferencing services. Keep this
    /// list short — extras are picked up by the "first URL" fallback.
    private static func isLikelyConferenceURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        let known = [
            "zoom.us", "zoom.com",
            "meet.google.com",
            "teams.microsoft.com", "teams.live.com",
            "webex.com",
            "discord.com", "discord.gg",
            "whereby.com",
            "around.co",
            "gather.town",
        ]
        return known.contains(where: { host == $0 || host.hasSuffix(".\($0)") })
    }

    private static func snapshot(from event: EKEvent, meEmails: Set<String>) -> CalendarEvent {
        // Group expansion: if any attendee email matches a user-defined
        // group mapping (Settings → Calendar → Group expansions), replace
        // the single group entry with its members. Lets us see real
        // people for events invited via Workspace groups, which EventKit
        // can't expand on its own.
        let groupExpansions = AppPreferences.shared.groupExpansions
        let rawAttendees = (event.attendees ?? []).map {
            attendee(from: $0, meEmails: meEmails)
        }
        let attendees: [CalendarAttendee] = rawAttendees.flatMap { entry -> [CalendarAttendee] in
            guard let email = entry.email?.lowercased(),
                  let members = groupExpansions[email],
                  !members.isEmpty else {
                return [entry]
            }
            return members.map { member in
                CalendarAttendee(
                    displayName: member.displayName,
                    email: member.email,
                    isMe: meEmails.contains(member.email),
                    role: entry.role,
                    status: entry.status
                )
            }
        }
        let organizer = event.organizer.map { attendee(from: $0, meEmails: meEmails) }
        let openURL = URL(string: "x-apple-calevent://\(event.eventIdentifier ?? "")")
        return CalendarEvent(
            eventIdentifier: event.eventIdentifier ?? UUID().uuidString,
            externalIdentifier: event.calendarItemExternalIdentifier,
            title: event.title ?? "Untitled event",
            startDate: event.startDate,
            endDate: event.endDate,
            location: event.location?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            conferenceURL: conferenceURL(from: event),
            calendarName: event.calendar?.title,
            organizer: organizer,
            attendees: attendees,
            openInCalendarURL: openURL
        )
    }

    private static func attendee(from p: EKParticipant, meEmails: Set<String>) -> CalendarAttendee {
        let email = Self.extractEmail(from: p.url)
        let name = p.name?.trimmingCharacters(in: .whitespaces).nilIfEmpty
            ?? email.flatMap { $0.components(separatedBy: "@").first }
            ?? "Unknown"
        let emailMatch = email.map { meEmails.contains($0.lowercased()) } ?? false
        let isMe = emailMatch || p.isCurrentUser
        return CalendarAttendee(
            displayName: name,
            email: email,
            isMe: isMe,
            role: roleString(p.participantRole),
            status: statusString(p.participantStatus)
        )
    }

    private static func extractEmail(from url: URL) -> String? {
        // EKParticipant.url is typically `mailto:foo@bar` — strip the scheme.
        guard let scheme = url.scheme else { return nil }
        if scheme == "mailto" {
            let path = url.absoluteString.dropFirst("mailto:".count)
            return path.isEmpty ? nil : String(path)
        }
        return nil
    }

    private static func roleString(_ role: EKParticipantRole) -> String {
        switch role {
        case .required: return "required"
        case .optional: return "optional"
        case .nonParticipant: return "non-participant"
        case .chair: return "chair"
        case .unknown: return "unknown"
        @unknown default: return "unknown"
        }
    }

    private static func statusString(_ status: EKParticipantStatus) -> String {
        switch status {
        case .unknown: return "unknown"
        case .pending: return "pending"
        case .accepted: return "accepted"
        case .declined: return "declined"
        case .tentative: return "tentative"
        case .delegated: return "delegated"
        case .completed: return "completed"
        case .inProcess: return "in-process"
        @unknown default: return "unknown"
        }
    }

    private static func mapAuth(_ status: EKAuthorizationStatus) -> Authorization {
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted, .denied: return .denied
        case .authorized, .fullAccess: return .authorized
        case .writeOnly: return .writeOnly
        @unknown default: return .denied
        }
    }

    private func meEmails() -> Set<String> {
        if let override = meEmailsOverride { return override }
        return AppPreferences.shared.myEmails
    }

    /// Best-effort guesses for the user's own email addresses, derived
    /// from EventKit metadata. Drives the "Suggested" chips in
    /// Settings → Calendar so the user doesn't have to type emails by
    /// hand. Sources, in order of reliability:
    ///   1. `EKSource.title` / `EKCalendar.title` containing "@" — Google
    ///      Workspace calendars sync with the account email as the
    ///      calendar title.
    ///   2. Any participant flagged `isCurrentUser=true` across the
    ///      currently loaded snapshot.
    func suggestedMyEmails() -> [String] {
        var out = Set<String>()
        // 1. Source/calendar titles that look like emails.
        for source in store.sources {
            if source.title.contains("@") {
                out.insert(source.title.lowercased())
            }
        }
        for cal in store.calendars(for: .event) {
            if cal.title.contains("@") {
                out.insert(cal.title.lowercased())
            }
        }
        // 2. Anything EventKit explicitly flagged as the current user.
        for ev in currentEvents + upcomingEvents {
            let participants = (ev.organizer.map { [$0] } ?? []) + ev.attendees
            for att in participants where att.isMe {
                if let e = att.email { out.insert(e.lowercased()) }
            }
        }
        return out.sorted()
    }
}

// MARK: - Small helpers

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
