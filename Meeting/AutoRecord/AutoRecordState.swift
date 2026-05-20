import Foundation

/// State machine for `AutoRecordScheduler`. Held in a `@Published` property
/// so SwiftUI surfaces (menu-bar label, countdown panel) can observe.
enum AutoRecordState: Equatable {
    case idle

    /// Scheduler has identified the next event to fire on and is waiting
    /// for `fireAt − countdownDuration` to elapse. `fireAt` is the event's
    /// `startDate`; the actual transition to `.countingDown` happens before
    /// it.
    case armed(event: CalendarEvent, fireAt: Date)

    /// Countdown panel is on screen. `subtitle` is the human-readable line
    /// from source resolution (e.g. "Zoom · 6 attendees" or "Recording
    /// primary display — couldn't find Zoom window"). `remaining` ticks
    /// 1Hz to 0, then the scheduler fires.
    case countingDown(event: CalendarEvent, subtitle: String, remaining: Int)
}

/// Reason an event was skipped instead of fired. Surfaced to the user via
/// `ToastPresenter` and recorded in the scheduler's session-local
/// suppressed-IDs set.
enum AutoRecordSuppressionReason: Equatable {
    case userCancelledThisOccurrence
    case alreadyRecording
    case missingScreenRecordingPermission
    case missingMicPermission
    case missingProcessAudioPermission
    case overlappingFireLostMatch
    case sourceUnavailableAndSkipFallback
    case eventStartedWhileMacAsleep
}

/// Prefs snapshot consumed by `AutoRecordEligibility`. Captured from
/// `AppPreferences` at evaluation time so the eligibility function stays
/// pure.
struct AutoRecordEligibilityPrefs: Equatable, Sendable {
    var masterEnabled: Bool
    var enabledCalendarIDs: Set<String>
}
