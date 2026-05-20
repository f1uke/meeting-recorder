# Auto-record — design

**Date:** 2026-05-20
**Status:** Approved — ready for implementation plan

## Goal

Automatically start a recording when an eligible calendar event begins, with a short
countdown the user can cancel. The user opts in to specific calendars; the master
toggle is off by default. Stopping stays manual.

## Scope

In scope:

- Observing the user's calendar for events that are about to start.
- Showing a borderless countdown panel ~N seconds before event start (N ∈ {3, 5, 10, 30}; default 5).
- Resolving the meeting's conference URL to a concrete capture source (window or display).
- Firing `RecordingSession.start(source:event:)` at T+0 unless the user cancels.
- Settings UI: master toggle, per-calendar opt-in, countdown duration, no-window fallback.

Out of scope:

- Auto-stop. The user picked manual-only stop.
- Per-event opt-out that persists across app restarts (in-memory only this iteration).
- Auto-launching the meeting app if it isn't running.
- Recording the meeting app's notifications, browser tabs other than the meeting tab, or system audio outside the meeting process.
- Telemetry on which recordings were auto-started.

## Existing infrastructure we build on

These are already in `main`. Auto-record reuses them rather than reinventing:

- `CalendarStore` (`Meeting/Calendar/CalendarStore.swift`) — publishes `currentEvents` and `upcomingEvents` (events overlapping ±15 min and the next 8 hours), refreshes on `EKEventStoreChanged` and every wall-clock minute, filters out all-day events.
- `CalendarMatcher` (`Meeting/Calendar/CalendarMatcher.swift`) — already has the conference-URL ↔ bundle-id mapping table we need for source resolution. Will be lifted into a shared `ConferenceURLAppMap`.
- `CalendarNotifier` (`Meeting/Calendar/CalendarNotifier.swift`) — owns the 5-minute pre-meeting `UNUserNotification`. Auto-record is conceptually parallel; they coexist.
- `CalendarEvent` — Sendable snapshot already persisted to `<meeting>/calendar.json`. Gains one new optional field (`calendarIdentifier`).
- `RecordingSession.start(source:event:)` — already accepts a `CalendarEvent`. No new public surface required.
- `CaptureSource` — already wraps either `SCWindow` or `SCDisplay`. Auto-record's resolver produces this same enum.
- `ToastPresenter` (`Meeting/App/ToastPresenter.swift`) — the borderless `nonactivatingPanel` pattern we copy for the countdown panel.

## Architecture

A new folder `Meeting/AutoRecord/` with five focused units:

```
Meeting/
  AutoRecord/
    AutoRecordScheduler.swift        // @MainActor ObservableObject; owns state machine
    AutoRecordState.swift            // enum State + Suppression value types
    AutoRecordEligibility.swift      // pure func: is this event eligible?
    AutoRecordSourceResolver.swift   // CalendarEvent → CaptureSource
    AutoRecordCountdownPanel.swift   // NSPanel host + SwiftUI content
  Calendar/
    ConferenceURLAppMap.swift        // NEW — lifted out of CalendarMatcher
    CalendarMatcher.swift            // now consumes ConferenceURLAppMap
    CalendarEvent.swift              // + calendarIdentifier: String?
    ...
  App/
    AppPreferences.swift             // + 4 new @AppStorage fields
    AppState.swift                   // owns AutoRecordScheduler
    SettingsView.swift               // + Auto-record section
```

`AppState` is the only place that wires the scheduler to the calendar store, the
recording session, the picker, and the permission status — exactly how
`CalendarNotifier` is wired today.

### `CalendarEventSource` protocol

To keep `AutoRecordScheduler` unit-testable without EventKit, introduce:

```swift
@MainActor
protocol CalendarEventSource: AnyObject {
    var upcomingEventsPublisher: Published<[CalendarEvent]>.Publisher { get }
    var currentEventsPublisher: Published<[CalendarEvent]>.Publisher { get }
}

extension CalendarStore: CalendarEventSource {
    var upcomingEventsPublisher: Published<[CalendarEvent]>.Publisher { $upcomingEvents }
    var currentEventsPublisher: Published<[CalendarEvent]>.Publisher { $currentEvents }
}
```

Tests inject a synthetic `CalendarEventSource` that publishes whatever events the
test wants without touching `EKEventStore`.

## State machine

```swift
enum AutoRecordState: Equatable {
    case idle
    case armed(event: CalendarEvent, fireAt: Date)
    case countingDown(event: CalendarEvent, source: CaptureSource, remaining: Int)
}

enum SuppressionReason: Equatable {
    case userCancelledThisOccurrence
    case alreadyRecording
    case missingPermission(Permission)
    case overlappingFireLostMatch
}
```

Transitions:

```
.idle ──[next eligible event ≤ 60s away]──► .armed(event, fireAt)

.armed ──[clock reaches fireAt − countdownDuration]──►
  resolve source off-main ──►
  .countingDown(event, source, remaining=countdownDuration)

.countingDown ──[1Hz tick]──► remaining-- (stays .countingDown)
.countingDown ──[remaining=0 or "Start now"]──►
  await recording.start(source:event:)
  ──► .idle
.countingDown ──[Cancel]──► .idle (add event ID to suppressedThisSession)

any state ──[masterToggle off]──► .idle
any state ──[event no longer in upcomingEvents]──► .idle
any state ──[event reschedule, |Δ|>30s]──► .idle then re-evaluate
```

### Scheduling without a per-event timer

The scheduler does not own a long-running timer. It piggybacks on
`CalendarStore`'s minute-tick + `EKEventStoreChanged` republishes. On each
publish:

1. Apply `AutoRecordEligibility` to filter `currentEvents + upcomingEvents`.
2. Of those, find the one whose `startDate` is closest in the future.
3. If that event is within 60 seconds of `now`, transition to `.armed(event, fireAt: event.startDate)`.
4. While `.armed`, run a single `Task.sleep` until `fireAt − countdownDuration`. On wake, transition to `.countingDown` (after off-main source resolution).
5. The `.armed` task is cancelled and rescheduled on every CalendarStore republish, so reschedules and event removals self-correct without polling.

This means the precision of `.armed → .countingDown` is bounded by `Task.sleep`
(sub-second), and the precision of "we noticed a new eligible event" is bounded
by the CalendarStore minute tick — fine, since `.armed` only needs to be set up
before fireAt, not "immediately when EK changes".

### Sleep/wake behavior

`Task.sleep` does not fire across system sleep. On wake, `CalendarStore`'s
minute tick re-publishes within ≤60s, and the scheduler re-evaluates. If
`fireAt` is already in the past, the scheduler does **not** retroactively
trigger; it transitions to `.idle` and adds the event ID to
`suppressedThisSession` so a subsequent tick doesn't notice it and try again.

## Source resolution

`AutoRecordSourceResolver` is a `struct` with a single async static function:

```swift
struct AutoRecordSourceResolver {
    static func resolve(
        event: CalendarEvent,
        fallback: SourceFallback
    ) async -> ResolveResult

    enum ResolveResult {
        case source(CaptureSource, subtitle: String)
        case skip(reason: String)
    }
}
```

Algorithm:

1. If `event.conferenceURL == nil` → return `.source(.display(primary), "Recording primary display")`.
2. Look up expected bundle IDs from `ConferenceURLAppMap.bundleIDs(for: url)`.
3. Fetch `SCShareableContent.current.windows`. Filter to windows whose
   `owningApplication.bundleIdentifier` matches.
4. Tie-break survivors with `ConferenceURLAppMap.preferredTitleSubstrings(for: bundleID)`. For browser-hosted meetings (Meet), additionally prefer windows whose title contains the event title.
5. If still multiple, pick the largest by `frame.area`.
6. Zero matches:
   - `fallback == .display` → `.source(.display(primary), "Recording primary display — couldn't find Zoom window")` (substitute the relevant app name).
   - `fallback == .skip` → `.skip("couldn't find Zoom window")`.

### `ConferenceURLAppMap`

Extracted as a new file under `Meeting/Calendar/ConferenceURLAppMap.swift`.
Single source of truth for "this conference URL host belongs to this set of
apps". Holds the existing table from `CalendarMatcher.appMatchesURL` plus a
`preferredTitleSubstrings` field. `CalendarMatcher` consumes the same struct so
the two features cannot drift.

```swift
enum ConferenceURLAppMap {
    struct AppEntry {
        let bundleIDPrefixes: [String]
        let hostSuffixes: [String]
        let displayName: String                 // "Zoom", "Google Meet"
        let preferredTitleSubstrings: [String]  // "Zoom Meeting", "Meet —"
    }

    static let entries: [AppEntry] = [ ... ]

    static func bundleIDs(for url: URL) -> [String]
    static func displayName(for bundleID: String) -> String?
    static func preferredTitleSubstrings(for bundleID: String) -> [String]
    static func appMatchesURL(bundleID: String, url: URL) -> Bool  // existing API
}
```

## Countdown UX

A new `AutoRecordCountdownPanel` host, modeled after `ToastPresenter`:

- Borderless `NSPanel`, `nonactivatingPanel`, `floating` level.
- Bottom-right of the active screen, slide-in from y+24, 0.25s easeOut.
- Cannot steal focus from the meeting app.

Content (SwiftUI inside a `GlassCard` with `.recordingDark` tint):

```
┌─────────────────────────────────────────────────────┐
│  ● Recording in 4s                                  │
│                                                     │
│  Q2 Roadmap Sync                          (serif)   │
│  Zoom · 6 attendees                       (dim)     │
│                                                     │
│  [ Cancel ]                  [ Start now ]          │
└─────────────────────────────────────────────────────┘
```

- Countdown number: `Font.mono` with `.tabular` digits, preceded by `PulseDot`.
- Title: `Font.serif`.
- Subtitle pattern:
  - `<displayName> · <attendeeCount> attendees` when window matched.
  - `Recording primary display` when no conference URL.
  - `Recording primary display — couldn't find Zoom window` when conference URL present but no window matched (and fallback is `.display`).
- `[Cancel]` is `GlassButton(.neutral)`, bound to ESC.
- `[Start now]` is `GlassButton(.accent)`, bound to Return as default button.

The existing `MenuBarLabel` gets a third idle variant: when
`scheduler.state == .countingDown(_, _, n)`, render `🎙 \(n)s` in mono. Plain
mic icon when scheduler is `.idle`. No changes to `RecordingSession.State`.

## Eligibility

Pure function. No dependencies on `EKEventStore` or `AppPreferences` — the
caller passes a `Prefs` snapshot.

```swift
struct AutoRecordEligibilityPrefs {
    var masterEnabled: Bool
    var enabledCalendarIDs: Set<String>
}

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
        // Declined-by-me check: any attendee with isMe=true and a "declined"
        // status excludes the event.
        if event.attendees.contains(where: { $0.isMe && $0.status == "declined" }) {
            return false
        }
        return true
    }
}
```

This depends on a new `status: String?` field on `CalendarAttendee` (covered in
the Persistence section below) — `role` stores `EKParticipantRole`
(required/optional/chair) and is not the right axis for "did this person
decline."

## Persistence

### `AppPreferences` — four new fields

| Key | Type | Default | Notes |
|---|---|---|---|
| `autoRecordEnabled` | `Bool` | `false` | Master toggle. |
| `autoRecordCountdownSeconds` | `Int` | `5` | UI constrains to `{3, 5, 10, 30}`. |
| `autoRecordEnabledCalendarIDs` | `Set<String>` (JSON in `UserDefaults`) | `[]` | EventKit calendar identifiers. |
| `autoRecordSourceFallback` | `SourceFallback` | `.display` | `display` or `skip`. |

`autoRecordEnabled == true && autoRecordEnabledCalendarIDs.isEmpty` is a valid
state — the scheduler stays idle and Settings nudges the user to pick at least
one calendar.

### `CalendarEvent` — one new field

```swift
let calendarIdentifier: String?
```

Populated by `CalendarStore.snapshot` from `event.calendar?.calendarIdentifier`.
Optional + Codable means old `calendar.json` files on disk continue to decode.

### `CalendarAttendee` — one new field

```swift
let status: String?  // "accepted", "declined", "tentative", ...
```

Populated by `CalendarStore.attendee(from:)` from `p.participantStatus`.
Optional + Codable means backward-compatible.

### Suppression set

In-memory `Set<String>` on the scheduler. Not persisted. Cleared on app
relaunch. Reason: a user's per-occurrence decision should not haunt them
forever; series-level muting is the per-calendar toggle's job.

## Settings UI

New section in `SettingsView`, between Calendar and Transcription:

```
Auto-record

  [x] Auto-record calendar meetings
      Start a recording with a 5-second confirmation
      when an eligible event begins.

  Confirmation window    ( 3s | [5s] | 10s | 30s )

  Calendars
    [x] Work                       fluke@company.com
    [x] Team @ Acme                fluke@company.com
    [ ] Personal                   me@gmail.com
    [ ] Holidays
    [ ] Birthdays

  When auto-record can't capture the right window
  (●) Record the primary display instead
  ( ) Skip the recording entirely
```

The calendar list is read from `CalendarStore` (which already enumerates
`store.calendars(for: .event)`). Each row binds to inclusion in
`autoRecordEnabledCalendarIDs`. Calendar names that look like email addresses
(Google Workspace) get the email displayed as a sub-label using the same
heuristic `CalendarStore.suggestedMyEmails` already uses.

When `CalendarStore.authorization != .authorized`, the entire section collapses
to an inline "Grant Calendar access" prompt that calls
`PermissionManager.request(.calendar)`.

## Edge cases & guards

| Situation | Behavior |
|---|---|
| `recording.state != .idle` at fireAt | Skip silently. Toast: "Q2 Sync started — already recording another session." Suppress event ID for the session. |
| Permission missing (screen / mic / audio-capture) | Skip. Toast: "Auto-record needs Screen Recording permission" + Open Settings button. Suppress for the session. |
| Calendar permission missing | Scheduler never runs. Settings section shows "Grant Calendar access" instead of toggles. |
| Overlapping events fire simultaneously | `CalendarMatcher.bestMatch` picks; loser suppressed for session, toast: "Skipped Town Hall — already started Q2 Sync." |
| Event reschedules during arm/countdown, |Δ|>30s | Cancel countdown, re-arm with new fireAt. |
| Event reschedules during arm/countdown, |Δ|≤30s | Keep countdown, quietly adjust fireAt. |
| Event removed from upcomingEvents (cancelled in calendar) | Tear down countdown. Toast: "Q2 Sync cancelled in calendar — auto-record stopped." |
| User declined the event | Filtered upstream by eligibility; never arms. |
| Event has no title | "Untitled event" — `CalendarStore.snapshot` already produces this string. |
| Source resolution finds no window, fallback=`.display` | Countdown proceeds; subtitle shows "Recording primary display — couldn't find Zoom window". |
| Source resolution finds no window, fallback=`.skip` | Skip with toast "Auto-record skipped — couldn't find Zoom window." Suppress for the session. |
| User puts Mac to sleep mid-arm | `Task.sleep` cancels. On wake, if `fireAt` is past, do NOT retroactively trigger; transition to `.idle` and suppress. |
| User puts Mac to sleep mid-countdown | Countdown task implicitly cancels. Same as above on wake. |
| User starts a recording manually 10s before fireAt | Scheduler sees `recording.state != .idle` at fireAt → skip + suppress. |
| Two countdowns competing | Impossible by construction — single-track state machine. |
| Master toggle flipped off mid-countdown | Tear down countdown immediately, return to `.idle`. |

## Testing

### Unit (no system frameworks)

- `AutoRecordEligibility` — synthetic events × prefs combinations. Covers all gates.
- `AutoRecordScheduler` — driven by a synthetic `CalendarEventSource`, a synthetic clock, and a recording-state stub. Covers every transition in the state machine, all edge-case rows above except sleep/wake (those need integration).
- `ConferenceURLAppMap` — table-driven test over Zoom / Meet / Teams / Webex / Discord / Slack. Includes a back-compat assertion: `CalendarMatcher.score(...)` produces identical output before and after the refactor.
- `AutoRecordSourceResolver` — URL→bundle-id portion only. The `SCShareableContent` half is covered by manual smoke.

### Integration

None new. Scheduler depends on the `CalendarEventSource` protocol, not the
concrete `CalendarStore`. `CalendarStore` already has its own coverage.

### Manual smoke (in the PR description)

- Eligible event with conference URL, app running → countdown fires, source matches window.
- Same event, app not running, fallback=`.display` → countdown fires, subtitle indicates fallback.
- Same event, fallback=`.skip` → no countdown, toast indicates skip.
- Back-to-back overlapping events → only one fires.
- Cancel during countdown → suppressed for session.
- Decline an invite → never arms.
- Sleep mid-arm, wake after meeting start → does not retroactively trigger.
- Master toggle off mid-countdown → panel disappears.
- Permission revoked while armed → skip + toast.

## Out of scope (deferred)

- Persisted per-occurrence opt-out. Today the suppression set is session-local; a future iteration may add `autoRecordSuppressedEventIDs` to `library.json` if users request it.
- Auto-stop variants (scheduled end, window-close, silence detection).
- "Re-arm in N minutes" snooze action on the countdown panel.
- Auto-launching the meeting app at fireAt.
- A `wasAutoStarted: Bool` flag in `calendar.json` for analytics. Not needed yet.
- Calendar-specific countdown overrides (different durations per calendar). The single-knob global setting is enough.

## Risks

- **`SCShareableContent.current` latency.** First call after launch can take ~200–500ms; calling it inside the `.armed → .countingDown` transition is fine because we're already off-main, but on a slow machine the countdown might effectively be `countdownDuration − 0.5s`. Acceptable.
- **EventKit calendar-identifier stability.** `EKCalendar.calendarIdentifier` is stable as long as the user doesn't delete and recreate a calendar. If they do, `autoRecordEnabledCalendarIDs` silently drops the recreated calendar. Settings UI surfaces all current calendars so the user can re-tick.
- **Conference URL hosts shifting.** Hosts can change (e.g. Teams adding new domains). `ConferenceURLAppMap` is a static table — needs updating when hosts move. Low cost to maintain; same risk exists in `CalendarMatcher` today.
- **User confusion at first launch.** Master toggle defaults off. The first time the user enables it, Settings shows an inline prompt explaining that no calendars are selected yet — the scheduler won't fire until they pick one.
