import Foundation

/// Pure-functional decision: should this calendar event ever trigger
/// auto-record? Pure so it's trivially testable without EventKit. All-day
/// events are filtered upstream by `CalendarStore` and are not re-checked
/// here.
enum AutoRecordEligibility {
    static func eligible(
        event: CalendarEvent,
        prefs: AutoRecordEligibilityPrefs,
        suppressedIDs: Set<String>,
        now: Date
    ) -> Bool {
        guard prefs.masterEnabled else { return false }
        guard let calID = event.calendarIdentifier,
              prefs.enabledCalendarIDs.contains(calID) else { return false }
        guard !suppressedIDs.contains(event.eventIdentifier) else { return false }
        guard event.endDate > now else { return false }
        if event.attendees.contains(where: { $0.isMe && $0.status == "declined" }) {
            return false
        }
        return true
    }
}
