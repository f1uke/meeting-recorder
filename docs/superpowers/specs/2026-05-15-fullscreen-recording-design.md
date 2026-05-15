# Full-screen recording

**Status:** Approved 2026-05-15
**Author:** Fluke

## Goal

Let the user record an entire display (with full system audio) in addition to
the existing single-window capture. The user wants to record in-person /
hybrid sessions where there is no single "meeting app" to tap, accepting that
diarization quality will degrade because `output.m4a` will contain everything
the system is playing (including Spotify, notifications, etc.).

## Non-goals

- A separate "tap audio from app X but record display Y" mode.
- Recording multiple displays at once.
- Trying to recover per-process audio separation after the fact.
- Surgical exclusion of Meeting's own UI sounds from the system tap beyond
  `stereoGlobalTapButExcludeProcesses: [self.pid]`.

## Source abstraction

Introduce a single enum that drives every layer below:

```swift
enum CaptureSource {
    case window(SCWindow)
    case display(SCDisplay)
}
```

`RecordingSession.start(window:event:)` becomes
`RecordingSession.start(source:event:)`. All downstream branches key off this
enum.

## Layer changes

### `ScreenCaptureCoordinator`

`start(source:videoURL:)`:

- `.window(win)` — unchanged: `SCContentFilter(desktopIndependentWindow: win)`,
  config size = `win.frame`.
- `.display(disp)` — new:
  `SCContentFilter(display: disp, excludingApplications: [<self SCRunningApplication>], exceptingWindows: [])`
  so Meeting's own popover / recording window does not show up in the captured
  video; config size = `disp.frame`.

Codec, fps, queue depth, FrameSink, recording-output delegate — unchanged.

### `ProcessAudioTap`

Add target enum:

```swift
enum TapTarget {
    case process(pid: pid_t, bundleID: String)
    case system
}
```

`start(target:url:rmsBuffer:)`:

- `.process` — current path (enumerate audio objects by bundle ID for
  Electron multi-helper apps, `CATapDescription(stereoMixdownOfProcesses:)`).
- `.system` — `CATapDescription(stereoGlobalTapButExcludeProcesses: [<self audio object>])`.
  Excluding self prevents the tap from re-recording our own UI sound
  effects. Same aggregate device + IOProc + `AVAudioFile` write path —
  `output.m4a` keeps its current format and the RMS pump still runs.

`processCount` reports `0` in `.system` mode (the chip UI hides on `0`, see
"UI rendering" below).

### `RecordingSession`

Step-by-step in `start(source:event:)`:

| Step | Window source | Display source |
|---|---|---|
| 1 SCStream | `coord.start(source: .window(win), ...)` | `coord.start(source: .display(disp), ...)` |
| 2 Mic | unchanged | unchanged |
| 3 ProcessAudioTap | `.process(pid, bundleID)` | `.system` |
| 4 MicGate | `MicGate.create(forBundleID:pid:)` | **skip** (no bundle ID) |
| 5 Meet scraper | Chrome + AX-trusted only | **skip** |
| 6 Context watchers (clipboard / browser) | unchanged | unchanged |

For `.display`:

- `currentSourceTitle` = `"Screen Recording"` (the equivalent of
  `win.title` — a name for the captured surface).
- `currentSourceApp` = display label (e.g. `"Built-in Retina Display"`;
  see "Display naming"). Placed in the "app" slot so the header reads
  `"{event.name or "Screen Recording"} — Built-in Retina Display"`,
  paralleling the window path's `"{event.name or win.title} — Zoom"`.
- `micGateState` / `micGateSource` stay `nil` — MenuBarLabel already guards
  on `nil` and won't render the mic-gate icon.
- `tapProcessCount` = `0`.

`stop()` does not need any new branches: the existing `if let gateFile` /
`if !participantNames.isEmpty` guards turn `.display` teardown into no-ops
for those sidecar files automatically.

### Calendar matching

`CalendarMatcher.bestMatch(events:, now:, windowBundleID:)` — for `.display`,
pass `windowBundleID: nil`. Falls back to time-only matching. Acceptable
because the user can still override the auto-pick via `CalendarNowCard`.

## Picker UI

### `WindowPickerModel`

```swift
enum PickerSource: Hashable {
    case window(CGWindowID)
    case display(CGDirectDisplayID)
}

@Published private(set) var displays: [SCDisplay] = []
@Published var selectedSource: PickerSource?

var selectedCaptureSource: CaptureSource? { ... }  // resolves to SCWindow/SCDisplay
```

`selectedWindowID: CGWindowID?` is removed; existing readers
(`PopoverIdleView.startRecording()`, `.disabled(...)`, `autoPickEventIfNeeded`)
switch to `selectedSource` / `selectedCaptureSource`.

`refresh()` reads both `content.windows` (existing filter) and
`content.displays` (no filter — every display is selectable) from one
`SCShareableContent.excludingDesktopWindows(...)` call.

On refresh, if the previously-selected source is gone (window closed, display
unplugged), clear `selectedSource` — mirrors the existing window-not-found
behaviour.

### Display naming

`SCDisplay` has no localized name. Match `disp.displayID` against
`NSScreen.screens` via the `"NSScreenNumber"` device-description key, then
read `NSScreen.localizedName` (e.g. `"Built-in Retina Display"`,
`"DELL U2723QE"`). Fallback: `"Display \(index+1)"`. If
`disp.displayID == CGMainDisplayID()`, append `" (primary)"` to the
displayed name.

### `WindowPicker` view

- Render a new `"Displays"` group at the top of the scroll view, before any
  app groups.
- Header reuses the `AppHeader` visual but with an SF Symbol
  (`"display"`) instead of an `NSRunningApplication.icon`.
- Each row (`DisplayRow`): symbol, name, dimensions (`width × height`),
  checkmark when selected. Click sets `selectedSource = .display(displayID)`
  via the same deferred-binding pattern used by `WindowRow` (avoids
  "Publishing changes from within view updates").
- App groups below the Displays group are unchanged.

### Start button

```swift
private func startRecording() {
    guard let source = picker.selectedCaptureSource else { return }
    let event = selectedEvent
    Task { await recording.start(source: source, event: event) }
}
```

`.disabled(picker.selectedCaptureSource == nil)`.

## Header rendering during recording

Both `PopoverRecordingView` and `RecordingWindowView` read
`currentSourceTitle` / `currentSourceApp`:

| Source | Title | App / subtitle |
|---|---|---|
| `.window(win)` | `event.name` or `win.title` | `applicationName` |
| `.display(disp)` | `event.name` or `"Screen Recording"` | display label (e.g. `"Built-in Retina Display"`) |

The tap-process-count chip in `PopoverRecordingView` switches from
"always-on" to `if tapProcessCount > 0` so it disappears in `.system`
mode rather than showing a confusing `0`.

`MenuBarLabel`'s mic-gate icon is already gated on `micGateState != nil`;
no changes required.

## Post-recording

No changes. `MeetingRecord`, Library, TranscriptViewer, and the
transcribe pipeline (`LocalProvider`, `TranscriptMerger`,
`TranscriptExporter`) all consume files (`video.mov`, `mic.m4a`,
`output.m4a`, `transcript.json`, etc.) whose schemas are identical.
Diarization will see whatever the system was playing — that is the
acceptable trade-off the user signed off on.

## Testing

### Unit (`MeetingTests/`)

- `CaptureSourceTests` — enum accessors (title, app name, bundle ID
  optional) resolve correctly for `.window` / `.display`.
- `WindowPickerModelTests` — `selectedCaptureSource` resolves to the right
  variant for `.window`/`.display`/`nil`; selection clears when the
  underlying source disappears on refresh.
- `DisplayNamingTests` — match by `displayID` returns
  `NSScreen.localizedName`; falls back to `"Display N"`; primary suffix
  attaches iff `displayID == CGMainDisplayID()`.
- `CalendarMatcherTests` — regression: `bestMatch(..., windowBundleID: nil)`
  still returns the best time-overlapping event.

### Manual smoke

- `.window` path — record Zoom window; confirm `output.m4a` contains only
  Zoom audio (regression guard).
- `.display` path on a single screen — open Spotify mid-recording;
  `output.m4a` includes voice + Spotify (confirms system tap is live).
- `.display` path on a multi-display setup — select the secondary
  display, drag the Meeting recording window onto it; `video.mov` must
  not contain Meeting's own UI (`excludingApplications: [self]` works).
- Stop & Transcribe completes on both paths; `transcript.md` is
  generated; TranscriptViewer opens.
- MicGate icon does not render during `.display` recording; tap-count
  chip is hidden in `.system` mode.
- First-time `.display` recording still surfaces the Screen Recording
  TCC prompt correctly (`CGPreflightScreenCaptureAccess` path
  unchanged).
