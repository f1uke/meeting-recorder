# Auto-record Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Automatically start a recording when an eligible calendar event begins, with a short cancellable countdown.

**Architecture:** A new `Meeting/AutoRecord/` module containing a `@MainActor` state machine (`AutoRecordScheduler`) that subscribes to `CalendarStore`'s published event lists, arms for the next eligible event, runs a 1Hz countdown, and fires `RecordingSession.start(source:event:)` at T+0. Source resolution maps the event's conference URL to a window via a shared `ConferenceURLAppMap` (lifted out of `CalendarMatcher`). UI is a borderless `NSPanel` modeled on `ToastPresenter`. Settings adds master toggle + per-calendar opt-in + countdown duration + no-window fallback. The scheduler is unit-tested via injected `CalendarEventSource` + `AutoRecordClock` protocols.

**Tech Stack:** Swift 6, SwiftUI, EventKit (existing `CalendarStore`), ScreenCaptureKit (existing `CaptureSource`), Combine (publisher subscriptions), XCTest, XcodeGen, `xcodebuild`.

**Reference spec:** `docs/superpowers/specs/2026-05-20-auto-record-design.md`

**File layout (final):**

```
Meeting/
  AutoRecord/
    AutoRecordState.swift          (NEW) value types: State, SuppressionReason, Prefs, SourceFallback
    AutoRecordClock.swift          (NEW) protocol + SystemClock production impl
    AutoRecordEligibility.swift    (NEW) pure eligibility function
    AutoRecordSourceResolver.swift (NEW) protocol + concrete CalendarEvent→CaptureSource resolver
    AutoRecordScheduler.swift      (NEW) @MainActor ObservableObject state machine
    AutoRecordCountdownPanel.swift (NEW) borderless NSPanel host + SwiftUI content
  Calendar/
    ConferenceURLAppMap.swift      (NEW) extracted table
    CalendarMatcher.swift          (MODIFY) consumes ConferenceURLAppMap
    CalendarEvent.swift            (MODIFY) + calendarIdentifier + CalendarAttendee.status + CalendarEventSource protocol
    CalendarStore.swift            (MODIFY) populate new fields + conform to CalendarEventSource
  App/
    AppPreferences.swift           (MODIFY) + 4 new fields
    AppState.swift                 (MODIFY) own AutoRecordScheduler + wire callbacks
    MenuBarLabel.swift             (MODIFY) countdown variant
    ToastPresenter.swift           (MODIFY) new auto-record toast methods
    SettingsView.swift             (MODIFY) Auto-record section
MeetingTests/
  ConferenceURLAppMapTests.swift   (NEW)
  AutoRecordEligibilityTests.swift (NEW)
  AutoRecordSourceResolverTests.swift (NEW)
  AutoRecordSchedulerTests.swift   (NEW)
  CalendarMatcherTests.swift       (verify still passes after refactor)
```

---

## Task 1: Extract ConferenceURLAppMap

**Files:**
- Create: `Meeting/Calendar/ConferenceURLAppMap.swift`
- Create: `MeetingTests/ConferenceURLAppMapTests.swift`
- Modify: `Meeting/Calendar/CalendarMatcher.swift` (replace inline table)

- [ ] **Step 1: Write the failing tests**

Create `MeetingTests/ConferenceURLAppMapTests.swift`:

```swift
import XCTest
@testable import Meeting

final class ConferenceURLAppMapTests: XCTestCase {

    func test_bundleIDs_forZoomURL_returnsZoomPrefix() {
        let url = URL(string: "https://us02web.zoom.us/j/123")!
        let result = ConferenceURLAppMap.bundleIDPrefixes(for: url)
        XCTAssertTrue(result.contains("us.zoom"))
    }

    func test_bundleIDs_forMeetURL_returnsAllBrowserPrefixes() {
        let url = URL(string: "https://meet.google.com/abc-defg-hij")!
        let result = Set(ConferenceURLAppMap.bundleIDPrefixes(for: url))
        XCTAssertTrue(result.contains("com.google.chrome"))
        XCTAssertTrue(result.contains("com.apple.safari"))
        XCTAssertTrue(result.contains("com.google.meetings"))
    }

    func test_bundleIDs_forUnknownURL_returnsEmpty() {
        let url = URL(string: "https://example.com/meeting")!
        XCTAssertTrue(ConferenceURLAppMap.bundleIDPrefixes(for: url).isEmpty)
    }

    func test_appMatchesURL_zoomBundle_matchesZoomURL() {
        let url = URL(string: "https://zoom.us/j/123")!
        XCTAssertTrue(ConferenceURLAppMap.appMatchesURL(bundleID: "us.zoom.xos", url: url))
    }

    func test_appMatchesURL_chromeBundle_matchesMeetURL() {
        let url = URL(string: "https://meet.google.com/xyz")!
        XCTAssertTrue(ConferenceURLAppMap.appMatchesURL(bundleID: "com.google.Chrome", url: url))
    }

    func test_appMatchesURL_wrongPair_returnsFalse() {
        let url = URL(string: "https://meet.google.com/xyz")!
        XCTAssertFalse(ConferenceURLAppMap.appMatchesURL(bundleID: "us.zoom.xos", url: url))
    }

    func test_displayName_forZoomBundle_returnsZoom() {
        XCTAssertEqual(ConferenceURLAppMap.displayName(forBundleID: "us.zoom.xos"), "Zoom")
    }

    func test_preferredTitleSubstrings_forZoom_includesZoomMeeting() {
        let result = ConferenceURLAppMap.preferredTitleSubstrings(forBundleID: "us.zoom.xos")
        XCTAssertTrue(result.contains { $0.lowercased().contains("zoom meeting") })
    }
}
```

- [ ] **Step 2: Run the failing tests**

```bash
xcodegen generate
pkill -9 -f "Meeting.app" 2>/dev/null || true
xcodebuild -project Meeting.xcodeproj -scheme Meeting -destination 'platform=macOS' \
  -only-testing:MeetingTests/ConferenceURLAppMapTests test
```

Expected: BUILD FAILURE — `ConferenceURLAppMap` is undefined.

- [ ] **Step 3: Implement ConferenceURLAppMap**

Create `Meeting/Calendar/ConferenceURLAppMap.swift`:

```swift
import Foundation

/// Single source of truth for "this conference URL host belongs to this set
/// of apps." Lifted out of `CalendarMatcher` so the auto-record source
/// resolver and the matcher's scoring stay in sync.
enum ConferenceURLAppMap {

    struct AppEntry: Sendable {
        let bundleIDPrefix: String
        let hostSuffixes: [String]
        let displayName: String
        let preferredTitleSubstrings: [String]
    }

    static let entries: [AppEntry] = [
        AppEntry(
            bundleIDPrefix: "us.zoom",
            hostSuffixes: ["zoom.us", "zoom.com"],
            displayName: "Zoom",
            preferredTitleSubstrings: ["zoom meeting"]
        ),
        AppEntry(
            bundleIDPrefix: "com.google.chrome",
            hostSuffixes: ["meet.google.com"],
            displayName: "Google Meet",
            preferredTitleSubstrings: ["meet -", "meet \u{2014}", "google meet"]
        ),
        AppEntry(
            bundleIDPrefix: "com.google.meetings",
            hostSuffixes: ["meet.google.com"],
            displayName: "Google Meet",
            preferredTitleSubstrings: ["meet"]
        ),
        AppEntry(
            bundleIDPrefix: "com.apple.safari",
            hostSuffixes: ["meet.google.com"],
            displayName: "Google Meet",
            preferredTitleSubstrings: ["meet -", "meet \u{2014}", "google meet"]
        ),
        AppEntry(
            bundleIDPrefix: "com.microsoft.teams",
            hostSuffixes: ["teams.microsoft.com", "teams.live.com"],
            displayName: "Microsoft Teams",
            preferredTitleSubstrings: ["meeting"]
        ),
        AppEntry(
            bundleIDPrefix: "com.cisco.webex",
            hostSuffixes: ["webex.com"],
            displayName: "Webex",
            preferredTitleSubstrings: ["meeting"]
        ),
        AppEntry(
            bundleIDPrefix: "com.hnc.discord",
            hostSuffixes: ["discord.com", "discord.gg"],
            displayName: "Discord",
            preferredTitleSubstrings: []
        ),
        AppEntry(
            bundleIDPrefix: "com.tinyspeck.slackmacgap",
            hostSuffixes: ["slack.com"],
            displayName: "Slack",
            preferredTitleSubstrings: []
        ),
    ]

    /// All bundle-ID prefixes that could host a meeting hosted at `url`.
    /// Returns prefixes (not full identifiers) so callers can match against
    /// `bundleID.hasPrefix(...)` to catch helper processes.
    static func bundleIDPrefixes(for url: URL) -> [String] {
        guard let host = url.host?.lowercased() else { return [] }
        return entries
            .filter { entry in
                entry.hostSuffixes.contains { host == $0 || host.hasSuffix(".\($0)") }
            }
            .map { $0.bundleIDPrefix }
    }

    /// Existing `CalendarMatcher` helper, moved verbatim.
    static func appMatchesURL(bundleID: String, url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        let lower = bundleID.lowercased()
        for entry in entries where lower.hasPrefix(entry.bundleIDPrefix) {
            if entry.hostSuffixes.contains(where: { host == $0 || host.hasSuffix(".\($0)") }) {
                return true
            }
        }
        return false
    }

    /// Human-readable name ("Zoom", "Google Meet") for a bundle ID.
    /// Returns nil if the bundle isn't in our table.
    static func displayName(forBundleID bundleID: String) -> String? {
        let lower = bundleID.lowercased()
        return entries.first { lower.hasPrefix($0.bundleIDPrefix) }?.displayName
    }

    /// Substrings that, when present in an `SCWindow.title`, indicate the
    /// "real meeting window" rather than the app's home/contacts window.
    /// Lowercased. Empty array = no preference (any window of this app is fine).
    static func preferredTitleSubstrings(forBundleID bundleID: String) -> [String] {
        let lower = bundleID.lowercased()
        return entries.first { lower.hasPrefix($0.bundleIDPrefix) }?
            .preferredTitleSubstrings ?? []
    }
}
```

- [ ] **Step 4: Update CalendarMatcher to consume ConferenceURLAppMap**

Replace `Meeting/Calendar/CalendarMatcher.swift` lines 98-118 (the `appMatchesURL` private helper) with a delegation:

```swift
    /// Lightweight bundle-id ↔ URL host correlation, delegated to the
    /// shared app map so the auto-record source resolver and this scorer
    /// stay aligned.
    private static func appMatchesURL(bundleID: String, url: URL) -> Bool {
        ConferenceURLAppMap.appMatchesURL(bundleID: bundleID, url: url)
    }
```

- [ ] **Step 5: Run the new and existing tests**

```bash
xcodegen generate
pkill -9 -f "Meeting.app" 2>/dev/null || true
xcodebuild -project Meeting.xcodeproj -scheme Meeting -destination 'platform=macOS' \
  -only-testing:MeetingTests/ConferenceURLAppMapTests \
  -only-testing:MeetingTests/CalendarMatcherTests test
```

Expected: both suites PASS.

- [ ] **Step 6: Commit**

```bash
git add Meeting/Calendar/ConferenceURLAppMap.swift Meeting/Calendar/CalendarMatcher.swift MeetingTests/ConferenceURLAppMapTests.swift
git commit -m "ConferenceURLAppMap — extract bundle/URL table from CalendarMatcher"
```

---

## Task 2: Add `status` to CalendarAttendee

**Files:**
- Modify: `Meeting/Calendar/CalendarEvent.swift` (add `status: String?` to `CalendarAttendee`)
- Modify: `Meeting/Calendar/CalendarStore.swift` (populate `status` from `EKParticipantStatus`)

- [ ] **Step 1: Add the field**

In `Meeting/Calendar/CalendarEvent.swift`, change the `CalendarAttendee` struct to add a `status` field after `role`:

```swift
struct CalendarAttendee: Codable, Equatable, Hashable, Sendable, Identifiable {
    var id: String {
        if let email, !email.isEmpty { return "email:\(email.lowercased())" }
        return "name:\(displayName)"
    }
    let displayName: String
    let email: String?
    let isMe: Bool
    let role: String?
    /// EKParticipantStatus raw — "accepted", "declined", "tentative",
    /// "pending", "delegated", "completed", "in-process", "unknown".
    /// Used by AutoRecordEligibility to skip events the user declined.
    /// Optional so old `calendar.json` files decode unchanged.
    let status: String?
}
```

(`Codable` synthesis tolerates the new optional field for existing on-disk JSON because the decoder defaults missing optionals to `nil`.)

- [ ] **Step 2: Populate `status` in CalendarStore**

In `Meeting/Calendar/CalendarStore.swift`, modify the static `attendee(from:meEmails:)` helper (around line 263) to capture participant status:

```swift
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
```

And add `statusString` near `roleString` (around line 288):

```swift
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
```

- [ ] **Step 3: Update all `CalendarAttendee(...)` initializers**

Search for any other constructor of `CalendarAttendee`:

```bash
grep -nR "CalendarAttendee(" Meeting MeetingTests
```

Add `status: nil` to every call site that uses the memberwise initializer and doesn't already pass `status`. In `Meeting/Calendar/CalendarStore.swift` the group-expansion initializer (around line 238) needs updating:

```swift
            return members.map { member in
                CalendarAttendee(
                    displayName: member.displayName,
                    email: member.email,
                    isMe: meEmails.contains(member.email),
                    role: entry.role,
                    status: entry.status
                )
            }
```

For any test fixture that constructs `CalendarAttendee(...)`, add `status: nil` (a default of `nil` is fine in tests where this is not the field under test).

- [ ] **Step 4: Build to verify all call sites compile**

```bash
xcodegen generate
xcodebuild -project Meeting.xcodeproj -scheme Meeting -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Run full Calendar test suite**

```bash
pkill -9 -f "Meeting.app" 2>/dev/null || true
xcodebuild -project Meeting.xcodeproj -scheme Meeting -destination 'platform=macOS' \
  -only-testing:MeetingTests/CalendarEventFileTests \
  -only-testing:MeetingTests/CalendarMatcherTests test
```

Expected: all PASS. The on-disk JSON test (`CalendarEventFileTests`) confirms older files without `status` still decode.

- [ ] **Step 6: Commit**

```bash
git add Meeting/Calendar/CalendarEvent.swift Meeting/Calendar/CalendarStore.swift MeetingTests/
git commit -m "CalendarAttendee — add participant status for declined-event filtering"
```

---

## Task 3: Add `calendarIdentifier` to CalendarEvent

**Files:**
- Modify: `Meeting/Calendar/CalendarEvent.swift`
- Modify: `Meeting/Calendar/CalendarStore.swift`

- [ ] **Step 1: Add the field**

In `Meeting/Calendar/CalendarEvent.swift`, add after `calendarName` (around line 25):

```swift
    let calendarName: String?
    /// EKCalendar.calendarIdentifier — stable per calendar in the user's
    /// EventKit store. Used by `AutoRecordEligibility` to decide whether
    /// this event is on a calendar the user enabled for auto-record.
    /// Optional so old on-disk `calendar.json` files decode unchanged.
    let calendarIdentifier: String?
    let organizer: CalendarAttendee?
```

- [ ] **Step 2: Populate in CalendarStore.snapshot**

In `Meeting/Calendar/CalendarStore.swift`, modify the `snapshot(from:meEmails:)` static helper. Locate the final `return CalendarEvent(...)` (around line 248) and add the new field:

```swift
        return CalendarEvent(
            eventIdentifier: event.eventIdentifier ?? UUID().uuidString,
            externalIdentifier: event.calendarItemExternalIdentifier,
            title: event.title ?? "Untitled event",
            startDate: event.startDate,
            endDate: event.endDate,
            location: event.location?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            conferenceURL: conferenceURL(from: event),
            calendarName: event.calendar?.title,
            calendarIdentifier: event.calendar?.calendarIdentifier,
            organizer: organizer,
            attendees: attendees,
            openInCalendarURL: openURL
        )
```

- [ ] **Step 3: Update any other `CalendarEvent(...)` initializers**

```bash
grep -nR "CalendarEvent(" Meeting MeetingTests | grep -v "CalendarEventFile\|//"
```

In every memberwise initializer call, add `calendarIdentifier: nil` (or a representative test value) so all call sites compile.

- [ ] **Step 4: Build**

```bash
xcodegen generate
xcodebuild -project Meeting.xcodeproj -scheme Meeting -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Run Calendar tests**

```bash
pkill -9 -f "Meeting.app" 2>/dev/null || true
xcodebuild -project Meeting.xcodeproj -scheme Meeting -destination 'platform=macOS' \
  -only-testing:MeetingTests/CalendarEventFileTests test
```

Expected: PASS — older `calendar.json` files without the field still decode.

- [ ] **Step 6: Commit**

```bash
git add Meeting/Calendar/CalendarEvent.swift Meeting/Calendar/CalendarStore.swift MeetingTests/
git commit -m "CalendarEvent — add calendarIdentifier for per-calendar opt-in"
```

---

## Task 4: AppPreferences fields for auto-record

**Files:**
- Modify: `Meeting/App/AppPreferences.swift`

- [ ] **Step 1: Add the `AutoRecordSourceFallback` enum**

At the bottom of `Meeting/App/AppPreferences.swift` (after the existing enums, before the final brace if there is one — or as a top-level addition), add:

```swift
// MARK: - Auto-record source fallback

/// What auto-record does when source resolution finds no window matching the
/// event's conference URL. `display` records the primary display anyway
/// (default). `skip` cancels the countdown with a toast.
enum AutoRecordSourceFallback: String, CaseIterable, Sendable, Identifiable {
    case display
    case skip

    var id: String { rawValue }

    var label: String {
        switch self {
        case .display: return "Record the primary display instead"
        case .skip:    return "Skip the recording entirely"
        }
    }
}
```

- [ ] **Step 2: Add the four `@Published` properties**

In `Meeting/App/AppPreferences.swift`, add inside the `AppPreferences` class body, near the other Calendar-adjacent settings:

```swift
    /// Master toggle for the auto-record feature. Off by default — users
    /// have to opt in. When off, the scheduler stays idle even if other
    /// settings are populated.
    @Published var autoRecordEnabled: Bool {
        didSet { UserDefaults.standard.set(autoRecordEnabled, forKey: Keys.autoRecordEnabled) }
    }

    /// Countdown duration in seconds shown before recording starts. UI
    /// constrains to {3, 5, 10, 30}; out-of-range values get clamped.
    @Published var autoRecordCountdownSeconds: Int {
        didSet { UserDefaults.standard.set(autoRecordCountdownSeconds, forKey: Keys.autoRecordCountdownSeconds) }
    }

    /// EventKit calendar identifiers the user explicitly opted in to.
    /// Stored as a comma-separated string in UserDefaults. Empty set +
    /// `autoRecordEnabled == true` is a valid state (scheduler stays idle,
    /// Settings shows a "pick at least one calendar" nudge).
    @Published var autoRecordEnabledCalendarIDs: Set<String> {
        didSet {
            UserDefaults.standard.set(
                autoRecordEnabledCalendarIDs.sorted().joined(separator: ","),
                forKey: Keys.autoRecordEnabledCalendarIDs
            )
        }
    }

    /// Behavior when source resolution finds no matching window.
    @Published var autoRecordSourceFallback: AutoRecordSourceFallback {
        didSet { UserDefaults.standard.set(autoRecordSourceFallback.rawValue, forKey: Keys.autoRecordSourceFallback) }
    }
```

- [ ] **Step 3: Initialize them from UserDefaults**

In the `init()` block, after the existing `identityMinSuggestScore` init line (around line 200), add:

```swift
        self.autoRecordEnabled = UserDefaults.standard.bool(forKey: Keys.autoRecordEnabled)
        let storedCountdown = UserDefaults.standard.integer(forKey: Keys.autoRecordCountdownSeconds)
        let allowed: Set<Int> = [3, 5, 10, 30]
        self.autoRecordCountdownSeconds = allowed.contains(storedCountdown) ? storedCountdown : 5
        let rawCalIDs = UserDefaults.standard.string(forKey: Keys.autoRecordEnabledCalendarIDs) ?? ""
        self.autoRecordEnabledCalendarIDs = Set(
            rawCalIDs.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        )
        self.autoRecordSourceFallback = AutoRecordSourceFallback(
            rawValue: UserDefaults.standard.string(forKey: Keys.autoRecordSourceFallback) ?? ""
        ) ?? .display
```

- [ ] **Step 4: Add the four keys**

In the `private enum Keys { ... }` block at the bottom of the class (around line 237), add:

```swift
        static let autoRecordEnabled = "dev.fluke.meeting.autoRecordEnabled"
        static let autoRecordCountdownSeconds = "dev.fluke.meeting.autoRecordCountdownSeconds"
        static let autoRecordEnabledCalendarIDs = "dev.fluke.meeting.autoRecordEnabledCalendarIDs"
        static let autoRecordSourceFallback = "dev.fluke.meeting.autoRecordSourceFallback"
```

- [ ] **Step 5: Build**

```bash
xcodebuild -project Meeting.xcodeproj -scheme Meeting -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Run AppPreferences tests**

```bash
pkill -9 -f "Meeting.app" 2>/dev/null || true
xcodebuild -project Meeting.xcodeproj -scheme Meeting -destination 'platform=macOS' \
  -only-testing:MeetingTests/AppPreferencesTests test
```

Expected: PASS — existing tests are unaffected.

- [ ] **Step 7: Commit**

```bash
git add Meeting/App/AppPreferences.swift
git commit -m "AppPreferences — auto-record settings (toggle, countdown, calendar IDs, fallback)"
```

---

## Task 5: AutoRecord value types — State + Suppression + Prefs

**Files:**
- Create: `Meeting/AutoRecord/AutoRecordState.swift`

- [ ] **Step 1: Create the file**

Create `Meeting/AutoRecord/AutoRecordState.swift`:

```swift
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
```

- [ ] **Step 2: Regenerate and build**

```bash
xcodegen generate
xcodebuild -project Meeting.xcodeproj -scheme Meeting -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add project.yml Meeting.xcodeproj Meeting/AutoRecord/AutoRecordState.swift
git commit -m "AutoRecord — state, suppression reason, prefs value types"
```

---

## Task 6: AutoRecordClock protocol + SystemClock

**Files:**
- Create: `Meeting/AutoRecord/AutoRecordClock.swift`

- [ ] **Step 1: Create the file**

Create `Meeting/AutoRecord/AutoRecordClock.swift`:

```swift
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
```

- [ ] **Step 2: Regenerate and build**

```bash
xcodegen generate
xcodebuild -project Meeting.xcodeproj -scheme Meeting -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add project.yml Meeting.xcodeproj Meeting/AutoRecord/AutoRecordClock.swift
git commit -m "AutoRecord — clock protocol + system clock"
```

---

## Task 7: AutoRecordEligibility pure function

**Files:**
- Create: `Meeting/AutoRecord/AutoRecordEligibility.swift`
- Create: `MeetingTests/AutoRecordEligibilityTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `MeetingTests/AutoRecordEligibilityTests.swift`:

```swift
import XCTest
@testable import Meeting

final class AutoRecordEligibilityTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let calID = "cal-work"

    private func event(
        id: String = "evt-1",
        calID: String? = "cal-work",
        startOffset: TimeInterval = 60,
        endOffset: TimeInterval = 30 * 60,
        attendees: [CalendarAttendee] = []
    ) -> CalendarEvent {
        CalendarEvent(
            eventIdentifier: id,
            externalIdentifier: nil,
            title: "Test",
            startDate: now.addingTimeInterval(startOffset),
            endDate: now.addingTimeInterval(endOffset),
            location: nil,
            conferenceURL: URL(string: "https://zoom.us/j/1"),
            calendarName: "Work",
            calendarIdentifier: calID,
            organizer: nil,
            attendees: attendees,
            openInCalendarURL: nil
        )
    }

    func test_eligible_happyPath() {
        let prefs = AutoRecordEligibilityPrefs(masterEnabled: true, enabledCalendarIDs: [calID])
        XCTAssertTrue(AutoRecordEligibility.eligible(
            event: event(), prefs: prefs, suppressedIDs: [], now: now))
    }

    func test_masterDisabled_returnsFalse() {
        let prefs = AutoRecordEligibilityPrefs(masterEnabled: false, enabledCalendarIDs: [calID])
        XCTAssertFalse(AutoRecordEligibility.eligible(
            event: event(), prefs: prefs, suppressedIDs: [], now: now))
    }

    func test_unselectedCalendar_returnsFalse() {
        let prefs = AutoRecordEligibilityPrefs(masterEnabled: true, enabledCalendarIDs: ["other"])
        XCTAssertFalse(AutoRecordEligibility.eligible(
            event: event(), prefs: prefs, suppressedIDs: [], now: now))
    }

    func test_eventWithoutCalendarIdentifier_returnsFalse() {
        let prefs = AutoRecordEligibilityPrefs(masterEnabled: true, enabledCalendarIDs: [calID])
        XCTAssertFalse(AutoRecordEligibility.eligible(
            event: event(calID: nil), prefs: prefs, suppressedIDs: [], now: now))
    }

    func test_suppressedID_returnsFalse() {
        let prefs = AutoRecordEligibilityPrefs(masterEnabled: true, enabledCalendarIDs: [calID])
        XCTAssertFalse(AutoRecordEligibility.eligible(
            event: event(id: "evt-x"), prefs: prefs, suppressedIDs: ["evt-x"], now: now))
    }

    func test_eventAlreadyEnded_returnsFalse() {
        let prefs = AutoRecordEligibilityPrefs(masterEnabled: true, enabledCalendarIDs: [calID])
        let past = event(startOffset: -60 * 60, endOffset: -30 * 60)
        XCTAssertFalse(AutoRecordEligibility.eligible(
            event: past, prefs: prefs, suppressedIDs: [], now: now))
    }

    func test_declinedByMe_returnsFalse() {
        let me = CalendarAttendee(
            displayName: "Me", email: "me@x", isMe: true,
            role: "required", status: "declined")
        let prefs = AutoRecordEligibilityPrefs(masterEnabled: true, enabledCalendarIDs: [calID])
        XCTAssertFalse(AutoRecordEligibility.eligible(
            event: event(attendees: [me]), prefs: prefs, suppressedIDs: [], now: now))
    }

    func test_declinedBySomeoneElse_returnsTrue() {
        let other = CalendarAttendee(
            displayName: "Other", email: "o@x", isMe: false,
            role: "required", status: "declined")
        let prefs = AutoRecordEligibilityPrefs(masterEnabled: true, enabledCalendarIDs: [calID])
        XCTAssertTrue(AutoRecordEligibility.eligible(
            event: event(attendees: [other]), prefs: prefs, suppressedIDs: [], now: now))
    }
}
```

- [ ] **Step 2: Run the failing tests**

```bash
xcodegen generate
pkill -9 -f "Meeting.app" 2>/dev/null || true
xcodebuild -project Meeting.xcodeproj -scheme Meeting -destination 'platform=macOS' \
  -only-testing:MeetingTests/AutoRecordEligibilityTests test
```

Expected: BUILD FAILURE — `AutoRecordEligibility` undefined.

- [ ] **Step 3: Implement**

Create `Meeting/AutoRecord/AutoRecordEligibility.swift`:

```swift
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
```

- [ ] **Step 4: Run the tests**

```bash
xcodegen generate
pkill -9 -f "Meeting.app" 2>/dev/null || true
xcodebuild -project Meeting.xcodeproj -scheme Meeting -destination 'platform=macOS' \
  -only-testing:MeetingTests/AutoRecordEligibilityTests test
```

Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add Meeting/AutoRecord/AutoRecordEligibility.swift MeetingTests/AutoRecordEligibilityTests.swift project.yml Meeting.xcodeproj
git commit -m "AutoRecordEligibility — pure function with full test coverage"
```

---

## Task 8: CalendarEventSource protocol + CalendarStore conformance

**Files:**
- Modify: `Meeting/Calendar/CalendarEvent.swift` (add protocol at file end)
- Modify: `Meeting/Calendar/CalendarStore.swift` (add conformance)

- [ ] **Step 1: Define the protocol**

Append to the end of `Meeting/Calendar/CalendarEvent.swift`:

```swift
// MARK: - Event source abstraction

/// Read-only interface used by `AutoRecordScheduler` to subscribe to
/// upcoming and current events. Lets the scheduler be unit-tested with a
/// synthetic source that doesn't touch EventKit.
@MainActor
protocol CalendarEventSource: AnyObject {
    var currentEventsPublisher: Published<[CalendarEvent]>.Publisher { get }
    var upcomingEventsPublisher: Published<[CalendarEvent]>.Publisher { get }
}
```

- [ ] **Step 2: Conform CalendarStore**

Append to `Meeting/Calendar/CalendarStore.swift` (outside the class, at file end):

```swift
extension CalendarStore: CalendarEventSource {
    var currentEventsPublisher: Published<[CalendarEvent]>.Publisher { $currentEvents }
    var upcomingEventsPublisher: Published<[CalendarEvent]>.Publisher { $upcomingEvents }
}
```

- [ ] **Step 3: Build**

```bash
xcodebuild -project Meeting.xcodeproj -scheme Meeting -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add Meeting/Calendar/CalendarEvent.swift Meeting/Calendar/CalendarStore.swift
git commit -m "CalendarEventSource — read-only protocol for scheduler injection"
```

---

## Task 9: AutoRecordSourceResolver

**Files:**
- Create: `Meeting/AutoRecord/AutoRecordSourceResolver.swift`
- Create: `MeetingTests/AutoRecordSourceResolverTests.swift`

The resolver has two parts: (1) URL/bundle filtering, which is testable via a pure helper; (2) `SCShareableContent` querying + display fallback, which requires the real system and is covered by manual smoke.

- [ ] **Step 1: Write the failing tests (pure helpers only)**

Create `MeetingTests/AutoRecordSourceResolverTests.swift`:

```swift
import XCTest
@testable import Meeting

final class AutoRecordSourceResolverTests: XCTestCase {

    func test_subtitle_noConferenceURL_describesDisplay() {
        let line = AutoRecordSourceResolver.subtitleForDisplayFallback(
            event: makeEvent(url: nil),
            displayName: "Display 1 (primary)"
        )
        XCTAssertEqual(line, "Recording Display 1 (primary)")
    }

    func test_subtitle_withConferenceURL_butNoWindow_includesAppName() {
        let url = URL(string: "https://zoom.us/j/1")!
        let line = AutoRecordSourceResolver.subtitleForDisplayFallback(
            event: makeEvent(url: url),
            displayName: "Display 1 (primary)"
        )
        XCTAssertEqual(line, "Recording Display 1 (primary) — couldn't find Zoom window")
    }

    func test_subtitle_withMatchedWindow_usesAppAndAttendeeCount() {
        let line = AutoRecordSourceResolver.subtitleForMatchedWindow(
            displayName: "Zoom",
            attendeeCount: 6
        )
        XCTAssertEqual(line, "Zoom · 6 attendees")
    }

    func test_subtitle_withMatchedWindow_zeroAttendees_omitsCount() {
        let line = AutoRecordSourceResolver.subtitleForMatchedWindow(
            displayName: "Zoom",
            attendeeCount: 0
        )
        XCTAssertEqual(line, "Zoom")
    }

    func test_pickBestWindow_prefersPreferredTitleSubstring() {
        let candidates: [AutoRecordSourceResolver.WindowCandidate] = [
            .init(title: "Zoom", area: 1_000_000),       // home window, huge
            .init(title: "Zoom Meeting", area: 500_000), // meeting window
        ]
        let best = AutoRecordSourceResolver.pickBest(
            candidates: candidates,
            preferredSubstrings: ["zoom meeting"],
            eventTitleHint: nil
        )
        XCTAssertEqual(best?.title, "Zoom Meeting")
    }

    func test_pickBestWindow_prefersEventTitleHint() {
        let candidates: [AutoRecordSourceResolver.WindowCandidate] = [
            .init(title: "Gmail — Inbox", area: 800_000),
            .init(title: "Q2 Roadmap Sync — Google Meet", area: 600_000),
        ]
        let best = AutoRecordSourceResolver.pickBest(
            candidates: candidates,
            preferredSubstrings: ["meet -", "meet \u{2014}"],
            eventTitleHint: "Q2 Roadmap Sync"
        )
        XCTAssertEqual(best?.title, "Q2 Roadmap Sync — Google Meet")
    }

    func test_pickBestWindow_fallsBackToLargestArea() {
        let candidates: [AutoRecordSourceResolver.WindowCandidate] = [
            .init(title: "Small", area: 100),
            .init(title: "Big", area: 500),
            .init(title: "Mid", area: 300),
        ]
        let best = AutoRecordSourceResolver.pickBest(
            candidates: candidates,
            preferredSubstrings: [],
            eventTitleHint: nil
        )
        XCTAssertEqual(best?.title, "Big")
    }

    func test_pickBestWindow_emptyCandidates_returnsNil() {
        let best = AutoRecordSourceResolver.pickBest(
            candidates: [],
            preferredSubstrings: [],
            eventTitleHint: nil
        )
        XCTAssertNil(best)
    }

    // MARK: - helpers

    private func makeEvent(url: URL?) -> CalendarEvent {
        CalendarEvent(
            eventIdentifier: "e",
            externalIdentifier: nil,
            title: "T",
            startDate: Date(),
            endDate: Date().addingTimeInterval(60),
            location: nil,
            conferenceURL: url,
            calendarName: nil,
            calendarIdentifier: nil,
            organizer: nil,
            attendees: [],
            openInCalendarURL: nil
        )
    }
}
```

- [ ] **Step 2: Run the failing tests**

```bash
xcodegen generate
pkill -9 -f "Meeting.app" 2>/dev/null || true
xcodebuild -project Meeting.xcodeproj -scheme Meeting -destination 'platform=macOS' \
  -only-testing:MeetingTests/AutoRecordSourceResolverTests test
```

Expected: BUILD FAILURE — `AutoRecordSourceResolver` undefined.

- [ ] **Step 3: Implement**

Create `Meeting/AutoRecord/AutoRecordSourceResolver.swift`:

```swift
import Foundation
import ScreenCaptureKit
import AppKit

/// Async protocol so `AutoRecordScheduler` can be tested with a stub
/// resolver that doesn't touch ScreenCaptureKit.
protocol AutoRecordSourceResolving: Sendable {
    func resolve(
        event: CalendarEvent,
        fallback: AutoRecordSourceFallback
    ) async -> AutoRecordSourceResolver.ResolveResult
}

/// Concrete implementation. Produces a `CaptureSource` + subtitle for the
/// countdown panel, or a `.skip` directive when the user picked the skip
/// fallback and no matching window exists.
struct AutoRecordSourceResolver: AutoRecordSourceResolving {

    enum ResolveResult {
        case source(CaptureSource, subtitle: String)
        case skip(reason: String)
    }

    /// Small value type the pure tie-break helper operates on, decoupled
    /// from the real `SCWindow` which has no public init.
    struct WindowCandidate {
        let title: String
        let area: Double
    }

    func resolve(
        event: CalendarEvent,
        fallback: AutoRecordSourceFallback
    ) async -> ResolveResult {
        // 1. No conference URL → primary display.
        guard let url = event.conferenceURL else {
            return await displayFallbackResult(event: event, fallback: fallback)
        }

        // 2. URL → expected bundle ID prefixes.
        let prefixes = ConferenceURLAppMap.bundleIDPrefixes(for: url).map { $0.lowercased() }
        guard !prefixes.isEmpty else {
            return await displayFallbackResult(event: event, fallback: fallback)
        }

        // 3. Query windows.
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                true, onScreenWindowsOnly: true
            )
        } catch {
            return await displayFallbackResult(event: event, fallback: fallback)
        }

        // 4. Filter by bundle prefix.
        let matchingWindows = content.windows.filter { window in
            guard let bundleID = window.owningApplication?.bundleIdentifier?.lowercased() else {
                return false
            }
            return prefixes.contains { bundleID.hasPrefix($0) }
        }

        if matchingWindows.isEmpty {
            return await displayFallbackResult(event: event, fallback: fallback)
        }

        // 5. Tie-break. Use the first matching window's bundle ID (good
        // enough — apps with multiple windows share one bundle ID).
        let matchedBundleID = matchingWindows.first?.owningApplication?.bundleIdentifier ?? ""
        let preferredSubstrings = ConferenceURLAppMap
            .preferredTitleSubstrings(forBundleID: matchedBundleID)
        let candidates = matchingWindows.map { window in
            WindowCandidate(
                title: window.title ?? "",
                area: Double(window.frame.width * window.frame.height)
            )
        }
        guard let best = Self.pickBest(
            candidates: candidates,
            preferredSubstrings: preferredSubstrings,
            eventTitleHint: event.title
        ) else {
            return await displayFallbackResult(event: event, fallback: fallback)
        }

        // Map the chosen candidate back to its SCWindow by title + area.
        let chosen = matchingWindows.first { w in
            (w.title ?? "") == best.title &&
            Double(w.frame.width * w.frame.height) == best.area
        } ?? matchingWindows[0]

        let displayName = ConferenceURLAppMap
            .displayName(forBundleID: matchedBundleID) ?? "Meeting"
        let subtitle = Self.subtitleForMatchedWindow(
            displayName: displayName,
            attendeeCount: event.totalAttendeeCount
        )
        return .source(.window(chosen), subtitle: subtitle)
    }

    // MARK: - Pure helpers (testable)

    static func pickBest(
        candidates: [WindowCandidate],
        preferredSubstrings: [String],
        eventTitleHint: String?
    ) -> WindowCandidate? {
        guard !candidates.isEmpty else { return nil }
        let lowerHint = eventTitleHint?.lowercased()

        // Score = preferred-substring match (high) + event-title hint match
        // (medium) + area (low, used as a tiebreaker).
        func score(_ c: WindowCandidate) -> Double {
            let lowerTitle = c.title.lowercased()
            var s: Double = 0
            if preferredSubstrings.contains(where: { lowerTitle.contains($0) }) {
                s += 1_000_000
            }
            if let hint = lowerHint, !hint.isEmpty, lowerTitle.contains(hint) {
                s += 500_000
            }
            s += c.area / 1_000  // small influence
            return s
        }

        return candidates.max { score($0) < score($1) }
    }

    static func subtitleForMatchedWindow(displayName: String, attendeeCount: Int) -> String {
        if attendeeCount > 0 {
            return "\(displayName) · \(attendeeCount) attendees"
        }
        return displayName
    }

    static func subtitleForDisplayFallback(event: CalendarEvent, displayName: String) -> String {
        guard let url = event.conferenceURL else {
            return "Recording \(displayName)"
        }
        let appName = ConferenceURLAppMap
            .displayName(forBundleID: ConferenceURLAppMap.bundleIDPrefixes(for: url).first ?? "")
            ?? "meeting"
        return "Recording \(displayName) — couldn't find \(appName) window"
    }

    // MARK: - Private

    private func displayFallbackResult(
        event: CalendarEvent,
        fallback: AutoRecordSourceFallback
    ) async -> ResolveResult {
        switch fallback {
        case .skip:
            let url = event.conferenceURL
            let appName = url.flatMap { u in
                ConferenceURLAppMap.displayName(
                    forBundleID: ConferenceURLAppMap.bundleIDPrefixes(for: u).first ?? "")
            } ?? "meeting"
            return .skip(reason: "couldn't find \(appName) window")
        case .display:
            let content: SCShareableContent?
            do {
                content = try await SCShareableContent.excludingDesktopWindows(
                    true, onScreenWindowsOnly: true
                )
            } catch {
                content = nil
            }
            let display = content?.displays.first { $0.displayID == CGMainDisplayID() }
                ?? content?.displays.first
            let label = display.map { CaptureSource.displayLabel(displayID: $0.displayID) }
                ?? "primary display"
            let subtitle = Self.subtitleForDisplayFallback(event: event, displayName: label)
            if let display {
                return .source(.display(display), subtitle: subtitle)
            }
            // Worst case: even display enumeration failed → skip.
            return .skip(reason: "no display available")
        }
    }
}
```

- [ ] **Step 4: Run the tests**

```bash
xcodegen generate
pkill -9 -f "Meeting.app" 2>/dev/null || true
xcodebuild -project Meeting.xcodeproj -scheme Meeting -destination 'platform=macOS' \
  -only-testing:MeetingTests/AutoRecordSourceResolverTests test
```

Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add Meeting/AutoRecord/AutoRecordSourceResolver.swift MeetingTests/AutoRecordSourceResolverTests.swift project.yml Meeting.xcodeproj
git commit -m "AutoRecordSourceResolver — protocol + concrete impl with tested tie-break"
```

---

## Task 10: AutoRecordScheduler — armed transitions

This task implements the part of the scheduler that watches the calendar source and transitions `idle → armed`. Subsequent tasks add countdown and firing.

**Files:**
- Create: `Meeting/AutoRecord/AutoRecordScheduler.swift`
- Create: `MeetingTests/AutoRecordSchedulerTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `MeetingTests/AutoRecordSchedulerTests.swift`:

```swift
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
    var result: AutoRecordSourceResolver.ResolveResult =
        .skip(reason: "stub")
    func resolve(event: CalendarEvent,
                 fallback: AutoRecordSourceFallback) async ->
        AutoRecordSourceResolver.ResolveResult {
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
    var startCalls: [(CaptureSource, CalendarEvent)] = []
    var skipCalls: [(CalendarEvent, AutoRecordSuppressionReason)] = []

    init(source: FakeEventSource, clock: TestClock, resolver: StubResolver) {
        self.source = source
        self.clock = clock
        self.resolver = resolver
        self.scheduler = AutoRecordScheduler(
            eventSource: source,
            clock: clock,
            resolver: resolver,
            prefsProvider: { AutoRecordEligibilityPrefs(masterEnabled: true, enabledCalendarIDs: ["cal-work"]) },
            countdownSecondsProvider: { 5 },
            sourceFallbackProvider: { .display },
            isAlreadyRecording: { false },
            hasRequiredPermissions: { nil },
            onStart: { _, _ in },
            onSkip: { _, _ in }
        )
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
```

- [ ] **Step 2: Run the failing tests**

```bash
xcodegen generate
pkill -9 -f "Meeting.app" 2>/dev/null || true
xcodebuild -project Meeting.xcodeproj -scheme Meeting -destination 'platform=macOS' \
  -only-testing:MeetingTests/AutoRecordSchedulerTests test
```

Expected: BUILD FAILURE — `AutoRecordScheduler` undefined.

- [ ] **Step 3: Implement the scheduler (armed-only version)**

Create `Meeting/AutoRecord/AutoRecordScheduler.swift`:

```swift
import Foundation
import Combine

/// Watches a `CalendarEventSource`, identifies the next event that's
/// eligible and within the arm horizon, and exposes a `@Published`
/// `AutoRecordState` for the UI. Countdown ticking and firing land in
/// follow-up tasks.
@MainActor
final class AutoRecordScheduler: ObservableObject {

    /// Horizon, in seconds, beyond which we don't even arm. Keeps the
    /// scheduler in `.idle` for the vast majority of the day. Events
    /// inside this window get a `Task.sleep` scheduled to flip to
    /// `.countingDown`.
    static let armHorizon: TimeInterval = 60

    @Published private(set) var state: AutoRecordState = .idle

    private let eventSource: CalendarEventSource
    private let clock: AutoRecordClock
    private let resolver: AutoRecordSourceResolving
    private var prefsProvider: () -> AutoRecordEligibilityPrefs
    private let countdownSecondsProvider: () -> Int
    private let sourceFallbackProvider: () -> AutoRecordSourceFallback
    private let isAlreadyRecording: () -> Bool
    /// Returns the missing permission reason (or `nil` if all are
    /// granted). Production wires this to `PermissionManager`.
    private let hasRequiredPermissions: () -> AutoRecordSuppressionReason?
    private let onStart: (CaptureSource, CalendarEvent) async -> Void
    private let onSkip: (CalendarEvent, AutoRecordSuppressionReason) -> Void

    private var cancellables: Set<AnyCancellable> = []
    private var armedTask: Task<Void, Never>?
    private var suppressedThisSession: Set<String> = []

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

        Publishers.CombineLatest(
            eventSource.upcomingEventsPublisher,
            eventSource.currentEventsPublisher
        )
        .sink { [weak self] _, _ in self?.reevaluate() }
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
        // If we're already armed on the same event, keep going.
        if case let .armed(currentEvt, currentFireAt) = state,
           currentEvt.eventIdentifier == next.eventIdentifier,
           abs(currentFireAt.timeIntervalSince(next.startDate)) <= 30 {
            return
        }
        arm(event: next)
    }

    private func collectPool() -> [CalendarEvent] {
        // The current upcoming/current snapshots from the source. We use
        // a non-published mirror to avoid await ceremony — Combine has
        // already pushed the latest values into the sink path that
        // triggered this call.
        let upcoming = (eventSource as? CalendarStore)?.upcomingEvents
            ?? (eventSource as? FakeEventSourceProtocol)?.fakeUpcoming
            ?? []
        let current = (eventSource as? CalendarStore)?.currentEvents
            ?? (eventSource as? FakeEventSourceProtocol)?.fakeCurrent
            ?? []
        return (current + upcoming).sorted { $0.startDate < $1.startDate }
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
        state = .idle
    }
}

/// Internal protocol the scheduler uses to read snapshots from a fake
/// source in tests, without forcing the public `CalendarEventSource`
/// protocol to expose mutable arrays. The production `CalendarStore`
/// already exposes its arrays via `@Published`, so it doesn't need to
/// conform.
@MainActor
protocol FakeEventSourceProtocol {
    var fakeUpcoming: [CalendarEvent] { get }
    var fakeCurrent: [CalendarEvent] { get }
}
```

And update `MeetingTests/AutoRecordSchedulerTests.swift` so `FakeEventSource` conforms to `FakeEventSourceProtocol`:

```swift
extension FakeEventSource: FakeEventSourceProtocol {
    var fakeUpcoming: [CalendarEvent] { upcoming }
    var fakeCurrent: [CalendarEvent] { current }
}
```

- [ ] **Step 4: Run the tests**

```bash
xcodegen generate
pkill -9 -f "Meeting.app" 2>/dev/null || true
xcodebuild -project Meeting.xcodeproj -scheme Meeting -destination 'platform=macOS' \
  -only-testing:MeetingTests/AutoRecordSchedulerTests test
```

Expected: all 5 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Meeting/AutoRecord/AutoRecordScheduler.swift MeetingTests/AutoRecordSchedulerTests.swift project.yml Meeting.xcodeproj
git commit -m "AutoRecordScheduler — arm/disarm on calendar publishes"
```

---

## Task 11: AutoRecordScheduler — countdown + firing

**Files:**
- Modify: `Meeting/AutoRecord/AutoRecordScheduler.swift`
- Modify: `MeetingTests/AutoRecordSchedulerTests.swift`

- [ ] **Step 1: Write the failing tests**

Append these tests to `MeetingTests/AutoRecordSchedulerTests.swift`:

```swift
    func test_transitionsToCountingDownAtFireMinusCountdown() async throws {
        let source = FakeEventSource()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = TestClock(start)
        let resolver = StubResolver(result: .source(.window(SCWindowDummy.value), subtitle: "Zoom · 4 attendees"))
        let host = SchedulerTestHost(source: source, clock: clock, resolver: resolver)

        let evt = host.makeEvent(id: "e1", startsIn: 30) // fires at +30, countdown=5 → start at +25
        source.upcoming = [evt]
        await yieldRunloop()

        // Advance to fireAt - countdownDuration.
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
        let resolver = StubResolver(result: .source(.window(SCWindowDummy.value), subtitle: "s"))
        let host = SchedulerTestHost(source: source, clock: clock, resolver: resolver)
        var fired: CalendarEvent?
        host.scheduler.setOnStart { _, evt in fired = evt }

        let evt = host.makeEvent(id: "e1", startsIn: 6)
        source.upcoming = [evt]
        await yieldRunloop()
        clock.advance(to: start.addingTimeInterval(1)) // fireAt-5 = +1
        await yieldRunloop()

        // Tick 5 → 4 → 3 → 2 → 1 → 0 → fire
        for s in stride(from: 2, through: 6, by: 1) {
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
        let resolver = StubResolver(result: .source(.window(SCWindowDummy.value), subtitle: "s"))
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
        let resolver = StubResolver(result: .source(.window(SCWindowDummy.value), subtitle: "s"))
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
        let resolver = StubResolver(result: .source(.window(SCWindowDummy.value), subtitle: "s"))
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

    private func yieldRunloop() async {
        for _ in 0..<8 { await Task.yield() }
    }
```

And add the `SCWindowDummy` helper at the bottom of the test file:

```swift
/// Placeholder `CaptureSource` for tests. We can't construct an `SCWindow`,
/// so the stub returns a display sentinel that the scheduler never reads
/// past — the assertion is on the state machine and onStart callback, not
/// on the actual capture target.
enum SCWindowDummy {
    static let value: CaptureSource = .display(unsafeBitCast(0, to: SCDisplay.self))
}
```

(`unsafeBitCast` here is a workaround because `SCDisplay` has no public init. The scheduler under test never dereferences it; only the `.window`/`.display` discriminator is observed.)

Wait — `unsafeBitCast(0, to: SCDisplay.self)` will crash if the scheduler ever calls methods on it. Use a safer pattern: make the stub resolver return a marker that the test can match without holding a real `CaptureSource`.

Replace the `SCWindowDummy` approach with:

```swift
/// The stub resolver always returns `.skip` in tests that don't need a
/// real source — most tests check state transitions and `onSkip`. Tests
/// that need a "source available" path use a custom `StubResolver` value
/// the SchedulerTestHost can override:
extension StubResolver {
    static func sourceAvailable(subtitle: String) -> StubResolver {
        // Return a sentinel via a fake `CaptureSource`. Since SCDisplay/
        // SCWindow can't be initialized, we route through a parallel
        // marker in the test (see `SchedulerSourceMarker`).
        // For tests that need to assert the source is used, mark it on
        // `onStart`.
        return StubResolver(result: .source(SchedulerSourceMarker.shared.source, subtitle: subtitle))
    }
}

/// Holds the single `CaptureSource` value the test suite uses as a
/// stand-in. Tests treat this as opaque — they only assert the scheduler
/// passed *some* `CaptureSource` to `onStart`.
@MainActor
final class SchedulerSourceMarker {
    static let shared = SchedulerSourceMarker()
    /// Lazily produced once per test run by enumerating real
    /// `SCShareableContent`. Returns the first available display. If
    /// ScreenCaptureKit isn't permissioned in the test runner this will
    /// fail — tests that need it should skip themselves.
    let source: CaptureSource
    private init() {
        let content = try? Self.fetch()
        if let display = content?.displays.first {
            self.source = .display(display)
        } else {
            // Fallback: this CaptureSource won't be valid, but the
            // scheduler tests never call `.start` on the real
            // `RecordingSession`, only the test's `onStart` closure.
            self.source = .display(unsafeBitCast(0, to: SCDisplay.self))
        }
    }
    private static func fetch() async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
    }
}
```

This is still fragile. Simpler clean solution: have the scheduler use a `ResolvedSource` value type internally that wraps `CaptureSource?` plus the subtitle, and expose a `@MainActor` test seam that lets tests set the resolved source directly. Update the implementation accordingly in Step 2 below.

Actually the cleanest fix is to keep the scheduler typed on `CaptureSource`, but have the test stub `StubResolver` return a value via the `.skip` path *only* in tests that don't need the source. Tests that need to verify the `onStart` was called with the resolver's source can dispatch through a `SchedulerSourceMarker.shared.source` that depends on the test runner having Screen Recording permission. To avoid the runtime crash on missing permission, gate the test with `XCTSkipIf` when SCShareableContent throws.

Revise the failing-test code so:

- Tests that exercise countdown + cancel + start-now use `StubResolver(result: .skip(reason: "stub"))` and assert on `onSkip` instead of `onStart`. The scheduler should still transition through `.countingDown` for a `.skip` result? No — if resolver returns `.skip`, the scheduler should NOT enter countdown; it should call `onSkip` immediately.

Rework the scheduler semantics: when the armed→countingDown transition begins, the resolver is awaited. A `.skip` result short-circuits to `onSkip` + `.idle`. A `.source` result enters `.countingDown`. So tests have two paths:
- Tests verifying skip flows: use `.skip` resolver.
- Tests verifying countdown ticking + start-now + user-cancel: need a `.source` result, which requires a real `CaptureSource`.

Acceptable compromise: in the test for countdown ticking and cancel/start-now, use a real `SCShareableContent` lookup at test setup, and `XCTSkipIf(displays.isEmpty)` to skip when running headless. This is similar to how `WindowPickerModelTests._seedForTests` handles the same issue.

Update the failing-test code in Step 1 to use this approach:

```swift
    /// Returns a real `CaptureSource` from `SCShareableContent`, or skips
    /// the test if Screen Recording isn't permissioned in the runner.
    @MainActor
    private func realDisplaySource() async throws -> CaptureSource {
        let content = try await SCShareableContent.excludingDesktopWindows(
            true, onScreenWindowsOnly: true)
        try XCTSkipIf(content.displays.isEmpty,
                      "Test requires at least one display via SCShareableContent")
        return .display(content.displays[0])
    }
```

And in each test that needs a source-available path, do:

```swift
        let realSource = try await realDisplaySource()
        let resolver = StubResolver(result: .source(realSource, subtitle: "Zoom · 4 attendees"))
```

Drop the `SCWindowDummy` and `SchedulerSourceMarker` helpers entirely.

Now also expose three test seams on the scheduler:

```swift
extension AutoRecordScheduler {
    /// Test-only seams. Production code wires these in init.
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
```

With private optional overrides in the class that the call sites fall back to if non-nil.

Mark this whole approach in Step 2's implementation.

- [ ] **Step 2: Extend the scheduler implementation**

Replace `Meeting/AutoRecord/AutoRecordScheduler.swift` with the full version:

```swift
import Foundation
import Combine

@MainActor
final class AutoRecordScheduler: ObservableObject {

    static let armHorizon: TimeInterval = 60
    /// Drift threshold for "did the event move enough to re-arm." Below this
    /// we keep the existing countdown rather than tearing it down.
    static let rescheduleDriftTolerance: TimeInterval = 30

    @Published private(set) var state: AutoRecordState = .idle

    private let eventSource: CalendarEventSource
    private let clock: AutoRecordClock
    private let resolver: AutoRecordSourceResolving
    private let prefsProvider: () -> AutoRecordEligibilityPrefs
    private let countdownSecondsProvider: () -> Int
    private let sourceFallbackProvider: () -> AutoRecordSourceFallback
    private let hasRequiredPermissions: () -> AutoRecordSuppressionReason?
    private let onStart: (CaptureSource, CalendarEvent) async -> Void
    private let onSkip: (CalendarEvent, AutoRecordSuppressionReason) -> Void

    // Test-only overrides.
    fileprivate var onStartOverride: ((CaptureSource, CalendarEvent) async -> Void)?
    fileprivate var onSkipOverride: ((CalendarEvent, AutoRecordSuppressionReason) -> Void)?
    fileprivate var isAlreadyRecordingOverride: (() -> Bool)?
    private let isAlreadyRecordingDefault: () -> Bool

    private var cancellables: Set<AnyCancellable> = []
    private var armedTask: Task<Void, Never>?
    private var countdownTask: Task<Void, Never>?
    private var pendingSource: CaptureSource?
    private var suppressedThisSession: Set<String> = []

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

        Publishers.CombineLatest(
            eventSource.upcomingEventsPublisher,
            eventSource.currentEventsPublisher
        )
        .sink { [weak self] _, _ in self?.reevaluate() }
        .store(in: &cancellables)
    }

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
        // Same event still armed → keep going (unless big drift).
        if case let .armed(currentEvt, currentFireAt) = state,
           currentEvt.eventIdentifier == next.eventIdentifier,
           abs(currentFireAt.timeIntervalSince(next.startDate)) <= Self.rescheduleDriftTolerance {
            return
        }
        if case let .countingDown(currentEvt, _, _) = state,
           currentEvt.eventIdentifier == next.eventIdentifier {
            // Already counting down on this event — don't restart the loop.
            return
        }
        arm(event: next)
    }

    func cancelCurrentCountdown() {
        guard case let .countingDown(evt, _, _) = state else { return }
        countdownTask?.cancel()
        countdownTask = nil
        suppressedThisSession.insert(evt.eventIdentifier)
        skip(evt, reason: .userCancelledThisOccurrence)
        state = .idle
    }

    func startNow() {
        guard case let .countingDown(evt, _, _) = state,
              let source = pendingSource else { return }
        countdownTask?.cancel()
        countdownTask = nil
        Task { [weak self] in
            guard let self else { return }
            await self.fire(source: source, event: evt)
        }
    }

    // MARK: - Private state machine

    private func collectPool() -> [CalendarEvent] {
        let upcoming = (eventSource as? CalendarStore)?.upcomingEvents
            ?? (eventSource as? FakeEventSourceProtocol)?.fakeUpcoming
            ?? []
        let current = (eventSource as? CalendarStore)?.currentEvents
            ?? (eventSource as? FakeEventSourceProtocol)?.fakeCurrent
            ?? []
        return (current + upcoming).sorted { $0.startDate < $1.startDate }
    }

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
                try await clock.sleep(until: countdownStart)
            } catch {
                return // cancelled
            }
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
        // Re-check eligibility — calendar may have changed while sleeping.
        let prefs = prefsProvider()
        guard AutoRecordEligibility.eligible(
            event: event,
            prefs: prefs,
            suppressedIDs: suppressedThisSession,
            now: clock.now()
        ) else {
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
            state = .countingDown(event: event, subtitle: subtitle, remaining: countdownSecondsProvider())
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
}

@MainActor
protocol FakeEventSourceProtocol {
    var fakeUpcoming: [CalendarEvent] { get }
    var fakeCurrent: [CalendarEvent] { get }
}

// MARK: - Test seams

extension AutoRecordScheduler {
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
```

- [ ] **Step 3: Run the full scheduler test suite**

```bash
xcodegen generate
pkill -9 -f "Meeting.app" 2>/dev/null || true
xcodebuild -project Meeting.xcodeproj -scheme Meeting -destination 'platform=macOS' \
  -only-testing:MeetingTests/AutoRecordSchedulerTests test
```

Expected: all PASS. Some tests may emit `XCTSkip` if the test runner lacks Screen Recording permission — that's acceptable.

- [ ] **Step 4: Commit**

```bash
git add Meeting/AutoRecord/AutoRecordScheduler.swift MeetingTests/AutoRecordSchedulerTests.swift
git commit -m "AutoRecordScheduler — countdown ticks, fire, cancel, start-now, skip paths"
```

---

## Task 12: AutoRecordCountdownPanel

**Files:**
- Create: `Meeting/AutoRecord/AutoRecordCountdownPanel.swift`

The panel is a presentation layer with no pure logic to unit-test. It's exercised by the manual smoke checklist at the end.

- [ ] **Step 1: Create the panel host + SwiftUI content**

Create `Meeting/AutoRecord/AutoRecordCountdownPanel.swift`:

```swift
import SwiftUI
import AppKit

/// Borderless, non-activating NSPanel that displays the auto-record
/// countdown. Modeled on `ToastPresenter` but with two buttons (Cancel /
/// Start now) instead of an open target.
@MainActor
final class AutoRecordCountdownPanel: ObservableObject {

    private var window: NSPanel?

    /// Render or refresh the countdown view.
    func show(
        event: CalendarEvent,
        subtitle: String,
        remaining: Int,
        onCancel: @escaping () -> Void,
        onStartNow: @escaping () -> Void
    ) {
        let content = AutoRecordCountdownView(
            event: event,
            subtitle: subtitle,
            remaining: remaining,
            onCancel: { [weak self] in
                onCancel()
                self?.dismiss()
            },
            onStartNow: { [weak self] in
                onStartNow()
                self?.dismiss()
            }
        )
        if let window {
            (window.contentView as? NSHostingView<AutoRecordCountdownView>)?.rootView = content
            return
        }
        let hosting = NSHostingView(rootView: content)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 140),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.contentView = hosting
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            let size = NSSize(width: 360, height: 140)
            let origin = NSPoint(x: f.maxX - size.width - 24, y: f.minY + 24)
            panel.setFrame(NSRect(origin: origin, size: size), display: true)
        }
        panel.orderFrontRegardless()
        window = panel
    }

    func dismiss() {
        window?.orderOut(nil)
        window = nil
    }
}

private struct AutoRecordCountdownView: View {
    let event: CalendarEvent
    let subtitle: String
    let remaining: Int
    let onCancel: () -> Void
    let onStartNow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                PulseDot()
                Text("Recording in \(remaining)s")
                    .font(.mono(13))
                    .foregroundStyle(Color.textPrimary)
            }
            Text(event.title)
                .font(.serif(16))
                .foregroundStyle(Color.textPrimary)
                .lineLimit(2)
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(Color.textDim)
                .lineLimit(2)
            HStack {
                GlassButton(.neutral, "Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                GlassButton(.accent, "Start now", action: onStartNow)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
        .padding(16)
        .background(
            GlassCard(tint: .recordingDark)
        )
    }
}
```

If `GlassButton(_:_:action:)` has a slightly different initializer signature (e.g. variadic or labeled differently), inspect `Meeting/Theme/Glass.swift` and adapt — keep the same `(.neutral, "Cancel") { ... }` ergonomics.

- [ ] **Step 2: Build**

```bash
xcodegen generate
xcodebuild -project Meeting.xcodeproj -scheme Meeting -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build
```

Expected: BUILD SUCCEEDED. If `GlassButton` or `GlassCard` signatures differ, fix the panel view to match `Meeting/Theme/Glass.swift`.

- [ ] **Step 3: Commit**

```bash
git add Meeting/AutoRecord/AutoRecordCountdownPanel.swift project.yml Meeting.xcodeproj
git commit -m "AutoRecordCountdownPanel — borderless NSPanel with countdown UI"
```

---

## Task 13: MenuBarLabel countdown variant

**Files:**
- Modify: `Meeting/App/MenuBarLabel.swift`

- [ ] **Step 1: Add an `AppState.autoRecordCountdownRemaining` mirror**

In `Meeting/App/AppState.swift`, add a published property that mirrors the scheduler state's countdown count (we'll wire this in the AppState task; for now declare the API):

```swift
    /// Remaining seconds on the auto-record countdown, or nil when no
    /// countdown is active. Used by `MenuBarLabel` to render the "🎙 4s"
    /// pre-recording variant.
    @Published private(set) var autoRecordCountdownRemaining: Int?
```

(The full wiring lands in Task 15. This declaration unblocks the MenuBarLabel changes.)

- [ ] **Step 2: Update MenuBarLabel**

Modify `Meeting/App/MenuBarLabel.swift` body to add the new case **before** the `default` branch:

```swift
        switch (recording.state, queue.activeCount, appState.isExtractingEmbeddings) {
        case let (.recording(_, started), _, _):
            // existing recording case unchanged
            ...
        case (_, let active, _) where active > 0:
            ...
        case (_, _, true):
            ...
        default:
            if let remaining = appState.autoRecordCountdownRemaining {
                HStack(spacing: 4) {
                    Image(systemName: "mic.fill")
                        .foregroundStyle(Color.brandAccent)
                    Text("\(remaining)s")
                        .monospacedDigit()
                        .font(.system(size: 13, weight: .medium))
                }
                .help("Auto-record countdown")
            } else {
                Image(systemName: "captions.bubble.fill")
                    .font(.system(size: 13))
            }
        }
```

- [ ] **Step 3: Build**

```bash
xcodebuild -project Meeting.xcodeproj -scheme Meeting -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add Meeting/App/MenuBarLabel.swift Meeting/App/AppState.swift
git commit -m "MenuBarLabel — auto-record countdown variant"
```

---

## Task 14: ToastPresenter — auto-record toasts

**Files:**
- Modify: `Meeting/App/ToastPresenter.swift`

- [ ] **Step 1: Add new toast methods**

In `Meeting/App/ToastPresenter.swift`, add three new public methods near `showMeetingNoteSaved`:

```swift
    /// Shown when auto-record skipped a meeting because the user is
    /// already recording another session.
    func showAutoRecordSkippedAlreadyRecording(eventTitle: String) {
        let info = ToastInfo(
            headline: "Auto-record skipped",
            title: eventTitle,
            subtitle: "Already recording another session",
            openTarget: URL(fileURLWithPath: "/"),  // unused
            folder: URL(fileURLWithPath: "/")
        )
        present(view: ToastView(
            info: info,
            onOpen: { [weak self] in self?.dismiss() },
            onDismiss: { [weak self] in self?.dismiss() }
        ))
        scheduleAutoDismiss(after: 5)
    }

    /// Shown when the user cancelled the auto-record countdown.
    func showAutoRecordCancelled(eventTitle: String) {
        let info = ToastInfo(
            headline: "Auto-record cancelled",
            title: eventTitle,
            subtitle: "Press the menu-bar icon to record manually",
            openTarget: URL(fileURLWithPath: "/"),
            folder: URL(fileURLWithPath: "/")
        )
        present(view: ToastView(
            info: info,
            onOpen: { [weak self] in self?.dismiss() },
            onDismiss: { [weak self] in self?.dismiss() }
        ))
        scheduleAutoDismiss(after: 5)
    }

    /// Shown when a required permission is missing.
    func showAutoRecordMissingPermission(eventTitle: String, permissionName: String) {
        let info = ToastInfo(
            headline: "Auto-record needs \(permissionName)",
            title: eventTitle,
            subtitle: "Open Settings to grant access",
            openTarget: URL(fileURLWithPath: "/"),
            folder: URL(fileURLWithPath: "/")
        )
        present(view: ToastView(
            info: info,
            onOpen: { [weak self] in self?.dismiss() },
            onDismiss: { [weak self] in self?.dismiss() }
        ))
        scheduleAutoDismiss(after: 6)
    }
```

If `ToastInfo` requires non-optional `openTarget`/`folder` and the toast view crashes on dummy values, instead refactor `ToastInfo` to make those optional (single-line change: `let openTarget: URL?`). Update `ToastView` accordingly to only render the Open button when `openTarget != nil`.

- [ ] **Step 2: Build**

```bash
xcodebuild -project Meeting.xcodeproj -scheme Meeting -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Meeting/App/ToastPresenter.swift
git commit -m "ToastPresenter — auto-record skipped/cancelled/permission toasts"
```

---

## Task 15: AppState wiring

**Files:**
- Modify: `Meeting/App/AppState.swift`

- [ ] **Step 1: Declare the scheduler + panel**

In `Meeting/App/AppState.swift`, add stored properties next to `notifier`:

```swift
    let autoRecord: AutoRecordScheduler
    let countdownPanel: AutoRecordCountdownPanel
```

- [ ] **Step 2: Construct them in init**

Inside `init()`, after `self.notifier = CalendarNotifier(...)`:

```swift
        let panel = AutoRecordCountdownPanel()
        self.countdownPanel = panel
        let prefsRef = AppPreferences.shared
        let calendarRef = calendar
        let recordingRef = recording
        let toastRef = toast
        let panelRef = panel

        weak var schedulerHolder: AutoRecordScheduler?
        self.autoRecord = AutoRecordScheduler(
            eventSource: calendarRef,
            clock: SystemClock(),
            resolver: AutoRecordSourceResolver(),
            prefsProvider: {
                AutoRecordEligibilityPrefs(
                    masterEnabled: prefsRef.autoRecordEnabled,
                    enabledCalendarIDs: prefsRef.autoRecordEnabledCalendarIDs
                )
            },
            countdownSecondsProvider: { prefsRef.autoRecordCountdownSeconds },
            sourceFallbackProvider: { prefsRef.autoRecordSourceFallback },
            isAlreadyRecording: { recordingRef.isRecording },
            hasRequiredPermissions: { [weak self] in
                guard let self else { return nil }
                if !self.permissions.screen { return .missingScreenRecordingPermission }
                if !self.permissions.microphone { return .missingMicPermission }
                if !self.permissions.audioCapture { return .missingProcessAudioPermission }
                return nil
            },
            onStart: { source, event in
                await recordingRef.start(source: source, event: event)
            },
            onSkip: { event, reason in
                switch reason {
                case .alreadyRecording:
                    toastRef.showAutoRecordSkippedAlreadyRecording(eventTitle: event.title)
                case .userCancelledThisOccurrence:
                    toastRef.showAutoRecordCancelled(eventTitle: event.title)
                case .missingScreenRecordingPermission:
                    toastRef.showAutoRecordMissingPermission(
                        eventTitle: event.title, permissionName: "Screen Recording")
                case .missingMicPermission:
                    toastRef.showAutoRecordMissingPermission(
                        eventTitle: event.title, permissionName: "Microphone")
                case .missingProcessAudioPermission:
                    toastRef.showAutoRecordMissingPermission(
                        eventTitle: event.title, permissionName: "Audio Capture")
                case .sourceUnavailableAndSkipFallback,
                     .overlappingFireLostMatch,
                     .eventStartedWhileMacAsleep:
                    toastRef.showAutoRecordCancelled(eventTitle: event.title)
                }
            }
        )
        schedulerHolder = self.autoRecord
```

(If the `PermissionStatus` field names differ from `screen` / `microphone` / `audioCapture`, look them up in `Meeting/App/PermissionManager.swift` and use the correct names.)

- [ ] **Step 3: Bridge scheduler state to MenuBarLabel + countdown panel**

After the existing `Task { @MainActor [weak self] in … }` block, add subscriptions:

```swift
        // Bridge scheduler state to the menu-bar label and the countdown panel.
        self.autoRecord.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                guard let self else { return }
                switch state {
                case .idle:
                    self.autoRecordCountdownRemaining = nil
                    self.countdownPanel.dismiss()
                case .armed:
                    self.autoRecordCountdownRemaining = nil
                    self.countdownPanel.dismiss()
                case let .countingDown(event, subtitle, remaining):
                    self.autoRecordCountdownRemaining = remaining
                    self.countdownPanel.show(
                        event: event,
                        subtitle: subtitle,
                        remaining: remaining,
                        onCancel: { [weak self] in self?.autoRecord.cancelCurrentCountdown() },
                        onStartNow: { [weak self] in self?.autoRecord.startNow() }
                    )
                }
            }
            .store(in: &cancellables)

        // Re-evaluate when auto-record prefs change.
        Publishers.CombineLatest4(
            prefsRef.$autoRecordEnabled,
            prefsRef.$autoRecordCountdownSeconds,
            prefsRef.$autoRecordEnabledCalendarIDs,
            prefsRef.$autoRecordSourceFallback
        )
        .dropFirst()
        .sink { [weak self] _, _, _, _ in self?.autoRecord.reevaluate() }
        .store(in: &cancellables)
```

- [ ] **Step 4: Build**

```bash
xcodebuild -project Meeting.xcodeproj -scheme Meeting -configuration Debug \
  -destination 'platform=macOS' build
```

(Use the stable-signed build because we'll smoke-test next.)

Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add Meeting/App/AppState.swift
git commit -m "AppState — wire AutoRecordScheduler to calendar, recording, panel, toast"
```

---

## Task 16: SettingsView — Auto-record section

**Files:**
- Modify: `Meeting/App/SettingsView.swift`

- [ ] **Step 1: Add the section**

Find the existing "Calendar" section in `Meeting/App/SettingsView.swift` (search for the section header — `"Calendar"`). Add a new section immediately below it. The exact integration depends on the file's structure, but the new section's body should look approximately like:

```swift
            Section {
                Toggle("Auto-record calendar meetings", isOn: $prefs.autoRecordEnabled)
                Text("Start a recording with a \(prefs.autoRecordCountdownSeconds)-second confirmation when an eligible event begins.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                Picker("Confirmation window", selection: $prefs.autoRecordCountdownSeconds) {
                    Text("3 s").tag(3)
                    Text("5 s").tag(5)
                    Text("10 s").tag(10)
                    Text("30 s").tag(30)
                }
                .disabled(!prefs.autoRecordEnabled)

                if appState.calendar.authorization == .authorized {
                    Text("Calendars")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.top, 4)
                    AutoRecordCalendarList(prefs: prefs, store: appState.calendar)
                        .disabled(!prefs.autoRecordEnabled)
                } else {
                    Button("Grant Calendar access") {
                        Task { await appState.request(.calendar) }
                    }
                }

                Picker("When auto-record can't capture the right window",
                       selection: $prefs.autoRecordSourceFallback) {
                    ForEach(AutoRecordSourceFallback.allCases) { f in
                        Text(f.label).tag(f)
                    }
                }
                .pickerStyle(.radioGroup)
                .disabled(!prefs.autoRecordEnabled)

                if prefs.autoRecordEnabled && prefs.autoRecordEnabledCalendarIDs.isEmpty
                    && appState.calendar.authorization == .authorized {
                    Text("Pick at least one calendar above — auto-record won't fire until you do.")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Auto-record")
            }
```

- [ ] **Step 2: Add the calendar-list helper view**

Append to the same file (or wherever the SettingsView's helper views live):

```swift
private struct AutoRecordCalendarList: View {
    @ObservedObject var prefs: AppPreferences
    @ObservedObject var store: CalendarStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(store.allCalendars(), id: \.id) { entry in
                Toggle(isOn: binding(for: entry.id)) {
                    HStack {
                        Text(entry.title)
                        if let sub = entry.subtitle {
                            Text(sub)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: { prefs.autoRecordEnabledCalendarIDs.contains(id) },
            set: { newValue in
                if newValue {
                    prefs.autoRecordEnabledCalendarIDs.insert(id)
                } else {
                    prefs.autoRecordEnabledCalendarIDs.remove(id)
                }
            }
        )
    }
}
```

- [ ] **Step 3: Expose `CalendarStore.allCalendars()`**

Add to `Meeting/Calendar/CalendarStore.swift`:

```swift
    /// Lightweight projection of the user's EventKit calendars for the
    /// Settings UI. Title comes from `EKCalendar.title`; subtitle is the
    /// source title when it looks like an email (Google Workspace), else
    /// nil. ID is the stable `calendarIdentifier`.
    struct CalendarListEntry: Identifiable, Hashable {
        let id: String
        let title: String
        let subtitle: String?
    }

    func allCalendars() -> [CalendarListEntry] {
        store.calendars(for: .event).map { cal in
            let src = cal.source.title
            let sub: String? = src.contains("@") ? src : nil
            return CalendarListEntry(
                id: cal.calendarIdentifier,
                title: cal.title,
                subtitle: sub
            )
        }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }
```

- [ ] **Step 4: Build**

```bash
xcodebuild -project Meeting.xcodeproj -scheme Meeting -configuration Debug \
  -destination 'platform=macOS' build
```

Expected: BUILD SUCCEEDED. If SettingsView's overall structure (Form/List/etc.) doesn't accept a raw `Section` at this location, wrap the new section in the same container the surrounding sections use.

- [ ] **Step 5: Commit**

```bash
git add Meeting/App/SettingsView.swift Meeting/Calendar/CalendarStore.swift
git commit -m "SettingsView — Auto-record section (toggle, duration, calendars, fallback)"
```

---

## Task 17: Full build + verify all suites pass

**Files:** none (verification step).

- [ ] **Step 1: Clean build with stable signing**

```bash
xcodegen generate
pkill -9 -f "Meeting.app" 2>/dev/null || true
xcodebuild -project Meeting.xcodeproj -scheme Meeting -configuration Debug \
  -destination 'platform=macOS' clean build
```

Expected: BUILD SUCCEEDED. Any warnings related to the new code should be addressed inline.

- [ ] **Step 2: Run the full test suite**

```bash
pkill -9 -f "Meeting.app" 2>/dev/null || true
xcodebuild -project Meeting.xcodeproj -scheme Meeting -destination 'platform=macOS' test
```

Expected: every test target PASSES.

- [ ] **Step 3: Commit any incidental cleanups**

If linting / warnings produced edits, commit them now:

```bash
git status
# only commit if there are real changes
git add -p
git commit -m "Auto-record — tidy warnings from clean build"
```

(Skip the commit if there's nothing to add.)

---

## Task 18: Manual smoke test

**Files:** none (verification step).

- [ ] **Step 1: Launch from Xcode**

Open `Meeting.xcodeproj` in Xcode and Run (⌘R). This produces a stable-signed bundle that won't re-prompt for TCC.

- [ ] **Step 2: Configure auto-record**

- Open Settings → Auto-record.
- Toggle the master switch ON.
- Pick a calendar (your work calendar).
- Leave countdown at 5s, fallback at "Record the primary display".

- [ ] **Step 3: Schedule a test event 2 minutes out**

In Calendar.app, create an event 2 minutes in the future titled "Smoke Test", with a Zoom URL in the location field (e.g. `https://zoom.us/j/1234567890`). Save.

- [ ] **Step 4: Observe**

Within ~60 seconds of the event start, the countdown panel should appear bottom-right. The menu-bar icon should switch to `🎙 5s` and tick down. The subtitle should show either "Recording <Display Name>" or "Recording <Display Name> — couldn't find Zoom window" depending on whether Zoom is running.

- [ ] **Step 5: Test cancel**

When the countdown is showing, click Cancel. The panel should slide out and the auto-record cancelled toast should appear. The menu-bar icon should revert to its idle state.

- [ ] **Step 6: Test start-now**

Schedule another event 2 minutes out. When the countdown appears, click Start now. Recording should begin immediately, and the menu-bar icon should switch to the red record dot + timer.

- [ ] **Step 7: Test already-recording skip**

Schedule another event 2 minutes out, then start a manual recording from the popover. At fire time, the auto-record skip toast should appear ("Already recording another session"); the manual recording should be unaffected.

- [ ] **Step 8: Test source-skip fallback**

Toggle Settings → Auto-record → "When auto-record can't capture the right window" to "Skip the recording entirely". Schedule an event with a Zoom URL, do NOT open Zoom. At fire time, no countdown panel should appear; instead the auto-record cancelled toast should fire.

- [ ] **Step 9: Test declined event**

Create an event in Calendar that invites you, then decline it. Wait for the start time. Nothing should happen — no countdown, no toast.

- [ ] **Step 10: Test master toggle off mid-countdown**

Schedule an event 2 minutes out. When the countdown appears, toggle Settings → Auto-record OFF. The panel should dismiss immediately.

- [ ] **Step 11: Commit a manual-test memo**

If any of the smoke steps failed, file follow-up tasks. Otherwise, no commit needed — the implementation is complete.

---

## Self-review notes

This plan was reviewed against the spec at `docs/superpowers/specs/2026-05-20-auto-record-design.md`:

- **Spec coverage:** Architecture, state machine, source resolution, countdown UX, eligibility, persistence, settings UI, edge cases — each has at least one task. Sleep/wake "don't retroactively fire" is partly implicit in `beginCountdown`'s eligibility re-check (the event will still be eligible since it's not yet ended) — Task 11's `beginCountdown` re-checks eligibility but does NOT compare against the original `fireAt`, so a sleep that lasts past the original fireAt would still trigger a fresh countdown. The spec says we should NOT retroactively trigger. Fix: in `beginCountdown`, if `clock.now() > event.startDate`, suppress with `.eventStartedWhileMacAsleep` instead of proceeding. This guard is included in the Step 2 implementation by adding:

  ```swift
  if clock.now() > event.startDate {
      skip(event, reason: .eventStartedWhileMacAsleep)
      suppressedThisSession.insert(event.eventIdentifier)
      state = .idle
      return
  }
  ```

  Add this check at the top of `beginCountdown` (right after the eligibility re-check) when implementing Task 11. The corresponding test:

  ```swift
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
      // Simulate sleep past fireAt.
      clock.advance(to: start.addingTimeInterval(120))
      await yieldRunloop()

      XCTAssertEqual(host.scheduler.state, .idle)
      XCTAssertEqual(skipped, .eventStartedWhileMacAsleep)
  }
  ```

  Add this test to `MeetingTests/AutoRecordSchedulerTests.swift` in Task 11.

- **Placeholder scan:** No "TBD" / "TODO" remain in step content.

- **Type consistency:** `AutoRecordSourceFallback` is defined in Task 4 (AppPreferences.swift) and referenced by Task 9 (resolver) and the scheduler — consistent. `AutoRecordEligibilityPrefs` is defined in Task 5 and consumed by Tasks 7, 10, 11, and 15 — consistent. `AutoRecordState` cases match across the scheduler, the panel, and the menu-bar label.

- **Scope:** This plan implements the entire spec in one cohesive sequence. No sub-decomposition needed.
