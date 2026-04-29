# Handoff: Meeting — macOS Menu Bar App UI

## Overview

This is a UI design handoff for **Meeting**, the existing native macOS app at the project root (Swift 6 / SwiftUI, target macOS 15). The current SwiftUI views (`PermissionView`, `RecordingMainView`, `WindowPicker`, etc.) are functional but minimal — this handoff is a complete UI redesign that turns the app into a **menu bar–first product** with a Library as its heart, plus polished Recording and Transcript views.

The recording engine, capture pipeline, transcription provider, and file layout described in `CLAUDE.md` are unchanged. **Only the SwiftUI views in `Meeting/App/` and `Meeting/Capture/` are being replaced**, plus a few new views for the Library and Transcript Viewer.

## About the design files

The files in this bundle are **design references created in HTML/React** — interactive prototypes that show the intended look, layout, typography, color, and behavior. They are **not production code to copy**. The task is to **recreate these designs in SwiftUI**, using the existing app's patterns (`@StateObject`, `@MainActor`, `WindowGroup`, `MenuBarExtra`, the existing `RecordingSession` / `TranscriptionSession` view models).

Open `Meeting.html` in a browser to see all screens on a single canvas.

## Fidelity

**High-fidelity.** Final colors, type, spacing, copy, and interactions are decided. Reproduce pixel-faithfully where SwiftUI primitives allow; substitute SF Symbols for the inline SVG icons in the prototype. The visual language is **macOS Tahoe "Liquid Glass"** — heavy use of `.regularMaterial` / `.thickMaterial`, translucent layers, inset highlights, and soft shadows. SwiftUI's built-in `Material`, `Glass` effects, and `.background(.ultraThinMaterial, in: RoundedRectangle(...))` should give you most of this for free.

---

## App-shape change: from WindowGroup to MenuBarExtra

Today the app is a single `WindowGroup`. The redesign moves the **primary entry point to the menu bar**:

```swift
@main
struct MeetingApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        // Menu bar icon + popover (primary entry point)
        MenuBarExtra {
            MenuBarPopoverView()
                .environmentObject(appState)
        } label: {
            MenuBarLabel()  // mic icon, becomes timer + red dot when recording
        }
        .menuBarExtraStyle(.window)  // popover, not a menu

        // Expanded windows — opened on demand from the popover
        Window("Library", id: "library") {
            LibraryView().environmentObject(appState)
        }
        .windowStyle(.hiddenTitleBar)  // we draw our own toolbar

        Window("Recording", id: "recording") { ... }
        Window("Transcript", id: "transcript") { ... }
    }
}
```

The existing `ContentView` (Permission gate → RecordingMainView) should be moved **inside the popover**: when permissions aren't granted, the popover shows the Permissions card; when they are, it shows the Idle / Recording / Transcribing state.

---

## Screens

### 1. Menu Bar Popover (primary surface)

**Width:** 360 pt. Anchored to the menu bar icon, with a small triangular tail pointing up to the icon.

The popover has **three states**, switched on the existing `RecordingSession.state` + `TranscriptionSession.state`:

#### 1a. Idle (`session.state == .idle`)

**Layout (top → bottom, 14 pt padding):**

- **Header row:** "Meeting" (15pt SF Pro semibold, -0.01em tracking) + "Ready to record" (11pt secondary). Right side: 26×26 glass icon buttons for search and settings.
- **SOURCE label** (10pt 700, 0.08em letter-spacing, uppercase, 45% black opacity)
- **Window chip** — single row card showing the picked window:
  - 32×32 rounded gradient app icon placeholder (use `NSRunningApplication.icon` from existing `WindowPickerModel`)
  - Title (12pt 600) + app name (11pt 55% black)
  - "Change" link on the right (11pt 600, accent color) — opens the WindowPicker as a small sheet
- **Speakers picker row** — same chip style as the existing `SpeakerCountPicker`, but as a tappable row showing "Expected speakers: 4" with a caret-down
- **Primary button row:**
  - Big accent-blue capsule "● Start Recording" (38pt height, full width)
  - 38×38 glass circular button "expand" — opens the full Recording window
- **RECENT section** (12 pt top margin, divider above):
  - "RECENT" label (10pt 700) + "Open Library →" link (11pt 600, accent) right-aligned
  - 3 recent meeting rows: small dot + title + duration (11pt) + when (11pt 40% black)

#### 1b. Recording (`session.state == .recording`)

- **Header row:** pulsing red dot (8×8, `box-shadow: 0 0 10px #ff5d57`, 1.6s `easeInOut` pulse) + "RECORDING" pill (12pt 700 uppercase) + monospace timer "00:14:32" (13pt 600, JetBrains Mono — substitute SF Mono in SwiftUI)
- "Q2 Roadmap Sync — Zoom" subtitle (12pt 70% black)
- **Two-channel waveform:**
  - "You (mic)" — 24 bars, cobalt blue (`oklch(0.7 0.15 250)`)
  - "Meeting" — 24 bars, warm red-orange (`oklch(0.78 0.16 25)`)
  - Each bar's height drives off the live RMS from `MicRecorder` / `ProcessAudioTap`; render from a ring buffer. Bar width = `flex: 1`, 2 pt gap, height max 24 pt, min 2 pt
  - Right side: "−15dB" peak readout (9pt mono)
- **Bookmarks row:** glass chip with flag icon (warm orange) + "3 moments marked" + "+ Mark" link on right. Wires to a new "marks" array on `RecordingSession`. Keyboard shortcut **⌘B**.
- **Controls row:** Pause (glass capsule, half width) + Stop & Transcribe (red gradient capsule, half width). Stop keeps the existing **⌘.** shortcut.

#### 1c. Transcribing (`transcribe.state == .running`)

Single glass card with progress: "Diarization 62%" + 6pt gradient progress bar (cobalt → cyan) + 4-segment pipeline (Mic → Output → Diarize → Merge — the existing `TranscriptionSession.Stage` cases). Subtitle: "Running locally on your Mac. No data leaves the device."

**Menu bar icon itself** (the `label:` in `MenuBarExtra`):
- Idle: SF Symbol `mic.fill`, monochrome
- Recording: red pulsing dot + monospace `00:14:32` timer next to the icon (use `Text(elapsed, format: .timeInterval(...))`)
- Transcribing: progress percent next to icon

---

### 2. Library — full window (the heart of the app)

**Window:** 1080 × 700, `.windowStyle(.hiddenTitleBar)`, `.windowResizability(.contentSize)` for min size, but resizable. Three columns.

#### 2a. Sidebar (220 pt wide)

- Frosted glass background: `Color(red: 0.88, green: 0.91, blue: 0.96).opacity(0.5)` over `.regularMaterial`
- Traffic lights at top (32 pt header row, 14 pt left padding) — let SwiftUI render them via `.windowStyle(.titleBar)` if you keep the titlebar, or draw them yourself if hidden
- Three groups (each: 10pt 700 uppercase header, 0.1em letter-spacing, 45% black; 4pt margin between rows; 7pt row radius):
  - **LIBRARY** — All meetings (124), Starred (9), Marked moments (38), Action items (17, with pulsing accent dot)
  - **TAGS** — colored 9pt dots: Engineering (cobalt), Design (magenta), People (warm), Research (green), 1:1 (gold)
  - **SPEAKERS** — small 16pt avatars (gradient circles with initial), "Show all 47…" muted footer
- Selected row: `Color.black.opacity(0.08)` background, 600-weight text
- **Footer storage card**: "STORAGE" label + 4pt gradient progress bar + "14.2 GB used / ~37 GB free" (10pt). Read from `URL.fileSystemResources` on `~/Documents/Meetings/`

#### 2b. List column (380 pt wide)

- 52pt toolbar: "All meetings" (15pt 700) + count + flexible space + 180pt search field (rounded 7pt, ⌘F shortcut hint) + 28×28 record button (red mic icon)
- Grouped scroll: TODAY / YESTERDAY / THIS WEEK / EARLIER (10pt 700 uppercase headers)
- **Meeting row** (10pt padding, 9pt radius, 2pt margin between):
  - 38×38 gradient avatar with two-letter initials from title
  - Title (12.5pt 600, single line, ellipsis)
  - Date (11pt 55% black)
  - Bottom row: clock icon + duration · users icon + count · tag pill (9.5pt 600, 4pt radius, tag color at 6% bg)
- **Selected row:** cobalt gradient (`oklch(0.7 0.16 250)` → `oklch(0.6 0.18 252)`), white text, soft shadow

#### 2c. Detail pane (flex)

- 52pt toolbar with right-aligned glass buttons: Play, Summary, Share, Export
- **Hero block:**
  - Tag pill + date · duration · "Recorded from Zoom" (11pt 55% black)
  - Title in **Instrument Serif** at 32pt, line-height 1.05, -0.01em tracking. Substitute "New York" (`Font.custom("New York", size: 32, relativeTo: .largeTitle)`) in SwiftUI for the serif — Apple's bundled serif.
- **AI Summary card** — translucent gradient background (subtle blue-violet wash), 14pt radius:
  - "✨ SUMMARY" label (11pt 700 uppercase, accent color)
  - 1–2 paragraph summary (13.5pt, 1.55 line-height, 78% black). Bold key phrases.
- **Action items list** (header "✓ Action items · 4", glass rows):
  - Empty 14pt rounded checkbox + speaker pill (10pt 700, accent bg) + text (12.5pt) + monospace timestamp (10pt, clickable to seek)
  - Each row clickable → opens transcript at that timestamp
- **Speakers strip** — 4 cards in flex row, each: avatar + name + total time (mono) + 3pt percentage bar in their color

#### Wiring Library to existing data

The capture layer writes to `~/Documents/Meetings/<yyyy-MM-dd_HH-mm-ss>/` with `video.mov`, `mic.wav`, `output.wav`, `transcript.json`, `transcript.md`, `transcript.srt`. Build a new `MeetingsLibrary` `@MainActor ObservableObject` that:

- Watches that folder with `DispatchSourceFileSystemObject` or `FSEvents`
- On change, reloads metadata (parse `transcript.json` for speakers/duration; read folder name for date)
- Persists user metadata (title overrides, tags, starred flag, custom speaker names) to `~/Library/Application Support/dev.fluke.meeting/library.json`

Match the existing `ModelStorage.downloadBase()` pattern — pass paths through, never touch `~/Documents/huggingface`.

---

### 3. Recording — expanded window

**Window:** 720 × 480. Dark glass: gradient navy/violet base, `.thinMaterial` overlay.

- 38pt titlebar (traffic lights left, "Meeting · Recording" centered 12pt 600)
- Status pill row: red dot + "RECORDING" pill (red-tinted glass) + "from **Zoom** — Q2 Roadmap Sync" (12pt)
- **72pt monospace timer**, font-weight 300, -0.04em tracking. Below it (right-aligned): "SAVING TO" (11pt uppercase) + folder path in mono (11pt 70% white)
- **Two big waveforms** (96 bars each, gradient cobalt for mic, gradient warm-orange for output): 36pt height, glass card per channel with label + sublabel ("Built-in Microphone" / "Zoom (4 audio processes)" — pull the count from the existing `ProcessAudioTap.collectAudioObjectIDs` log) + dB readout
- **Bottom row:** marks card (flag + "3 moments marked · last at 12:08" + "+ Mark moment ⌘B") + 44pt circular pause button + 44pt red gradient "Stop & Transcribe ⌘." capsule

---

### 4. Transcript Viewer

**Window:** 1180 × 760. Three-column glass.

- 56pt **icon nav rail** on the left (traffic lights + 36×36 glass icon buttons: list / search / sparkles (active) / flag / users — and bottom: record / settings)
- 52pt toolbar: breadcrumb "Library › Q2 Roadmap Sync" + 240pt search field with live hit count ("4 hits") + Summary, Export, Share buttons
- **Left column (380pt)** — stacked:
  - **Video preview** (16:10) — fake meeting tile grid in proto; in real app, render `video.mov` via `AVPlayer`. Below: scrubber with current/total mono timestamps + 3pt track + position thumb + **moment markers** as 2×7 warm-orange ticks at marked timestamps
  - **Speakers card** — header "SPEAKERS · 4 / Edit" — 4 rows: avatar + name + total time (mono). Click "Edit" → name becomes inline `TextField`; saving writes to library.json + offers "Apply to all past meetings" (matches by voice fingerprint via SpeakerKit's embedding cache)
  - **Moments card** — clickable rows: mono timestamp + note. Click → seek video.
- **Right column (transcript)** — scrollable:
  - Hero: serif title (36pt) + meta line
  - Segments rendered from `transcript.json` (use the existing `TranscriptExporter` model). Each segment:
    - Left col (96pt): speaker avatar + name (12pt 600) + monospace timestamp below (11pt 50%, clickable to seek video)
    - Right col: text at **14pt, line-height 1.6**
  - **States to support per segment:**
    - **Default** — plain text
    - **Search match** — wrap matched runs in `<mark>` with warm-yellow background (`oklch(0.9 0.15 90 / 0.6)`)
    - **Editing** — segment becomes a `TextEditor` with cobalt 1px border + 3pt cobalt glow (`shadow(color: .accentColor.opacity(0.15), radius: 0, y: 0)` × ring)
    - **Highlight (action item)** — 2px left accent border, soft warm gradient bg, "ACTION ITEM" pill + "Auto-detected by Claude" subtitle below text

#### AI features — implementation pointers

- **Summary + action items**: call the user's chosen LLM (likely add an `LLMProvider` protocol mirroring `TranscriptionProvider`) on the transcript markdown after transcription completes. Cache the result in `summary.json` next to the transcript. Re-run on demand from a button. Don't do this without a user setting — keep "no data leaves the device" as the default and require explicit opt-in for any cloud LLM.

---

### 5. Permissions (480pt sheet, in the popover when permissions aren't granted)

Already mostly built in `PermissionView.swift`. Restyle to match:

- 56×56 cobalt gradient lock icon at top
- Serif "Permissions" title (30pt) + subtitle "Meeting needs three macOS privileges to record cleanly. Everything runs locally."
- Three glass rows (matches existing `Permission.allCases`):
  - 32×32 status icon (green-tinted bg if granted, neutral if not)
  - Title + detail
  - Right side: green "✓ Granted" label OR cobalt "Allow" pill button

### 6. Toast: transcript ready

360pt glass card slid in via `NSWindow` with `.floating` level, top-right of screen, auto-dismiss after 8s:
- 38×38 green gradient ✓ icon + "Transcript ready" / "Q2 Roadmap Sync · 47m · 4 speakers" + cobalt "Open" button (opens the Transcript window with that meeting selected)

Use `UNUserNotificationCenter` instead if you want it to live in Notification Center too.

---

## Design tokens

### Colors (use `Color` initializers)

| Token | Light | Dark | Usage |
|---|---|---|---|
| `accent` | `oklch(0.65 0.18 250)` ≈ `#3b82f6` ish | same | primary buttons, links, selection |
| `accent-strong` | `oklch(0.55 0.18 252)` | same | gradient end |
| `record-red` | `#ff5d57` (idle) → `#e94942` (gradient end) | same | record dot, stop button |
| `warm-mark` | `oklch(0.78 0.16 25)` ≈ `#f0793f` | same | bookmarks, action items |
| `success` | `oklch(0.45 0.18 145)` ≈ `#1d9c5b` | same | granted state, "transcript ready" |
| `text-primary` | `#0c0e14` | `#e8eaef` | |
| `text-dim` | 55% black | `#9aa0ac` | |
| `text-faint` | 40% black | `#5b6370` | |
| `glass-light` | `rgba(255,255,255,0.55)` | `rgba(255,255,255,0.08)` | popover, cards |
| `glass-tinted` | `rgba(225,232,245,0.5)` | `rgba(20,30,50,0.45)` | sidebar |
| `glass-dark` | — | `rgba(20,22,30,0.4)` | recording window |

Tag colors (sidebar dots, list pills): all `oklch(0.7 0.16 H)` with H ∈ {250 cobalt, 320 magenta, 30 warm, 145 green, 75 gold}.

In SwiftUI prefer `.background(.regularMaterial)` (matches Tahoe Liquid Glass) over hand-rolled translucency. Add `.shadow(.inner)` for the inset highlight where needed.

### Typography

| Style | Font | Size / weight | Tracking |
|---|---|---|---|
| Hero title | New York (serif) | 32–36pt regular | -0.01em |
| Window/section title | SF Pro | 15pt semibold | -0.01em |
| Body | SF Pro | 13.5–14pt regular | normal |
| Small label | SF Pro | 11pt medium | normal |
| **UPPERCASE LABEL** | SF Pro | 10–11pt 700 | 0.08–0.1em |
| Timer (recording window) | SF Mono | 72pt light | -0.04em, tabular-nums |
| Timestamps, dB, paths | SF Mono | 10–11pt regular | tabular-nums |

### Spacing & radii

- Window radius: 16pt (system default)
- Card radius: 12–14pt
- Pill radius: 999
- Padding: 14pt inside cards, 16–24pt inside main panes
- Bar gap (waveforms): 1.5–2pt

### Shadows

- Window: `0 32px 80px rgba(0,0,0,0.4)` + 0.5pt hairline border
- Card: `0 12px 36px rgba(0,0,0,0.18)` + inset top highlight `inset 0 1px 0 rgba(255,255,255,0.55)`
- Accent button: `0 6px 18px <accent at 45%>`
- Red stop button: `0 8px 22px rgba(233,73,66,0.45)`

### Motion

- Pulse (record dot): `easeInOut`, 1.6s, opacity 1 → 0.45 → 1
- Cursor blink (transcript editing): step, 1s
- Popover entry: `.scale(0.98).opacity(0)` → identity, 180ms `easeOut`
- Toast: spring slide from top-right, `.spring(response: 0.4, dampingFraction: 0.8)`

---

## Interactions & behavior

| Trigger | Action |
|---|---|
| Click menu bar icon | Toggle popover |
| Click "Start Recording" | Run existing `session.start(window:)` flow; popover stays open showing recording state |
| Click expand (38pt circle) | Open Recording window (720×480), keep popover dismissable |
| ⌘B during recording | Append timestamp to `session.marks: [TimeInterval]`; flash a green "Marked" hint |
| ⌘. during recording | Stop & start transcription (existing flow) |
| Click meeting in Library | Select; detail pane updates |
| Double-click meeting | Open Transcript window |
| Click timestamp in transcript | `AVPlayer.seek` to that time |
| Click speaker name in transcript | Inline rename → write to `library.json` → re-render all instances |
| Click segment text | Switch to TextEditor; ⏎ saves, Esc cancels |
| ⌘F in Library or Transcript | Focus search field |
| ⌘E in transcript | Open export sheet (Markdown / SRT / JSON — already implemented in `TranscriptExporter`) |
| Drag meeting row → folder | Export the entire meeting folder |

---

## State management

Reuse what exists. Add:

```swift
@MainActor
final class MeetingsLibrary: ObservableObject {
    @Published var meetings: [MeetingRecord] = []
    @Published var selection: MeetingRecord.ID?
    @Published var search: String = ""
    @Published var selectedTag: Tag?
    @Published var selectedSpeaker: String?
    // Watches ~/Documents/Meetings/ via FSEvents
}

struct MeetingRecord: Identifiable, Codable {
    let id: UUID
    let folder: URL
    var title: String          // overridable; default = folder name
    var tags: [String]
    var starred: Bool
    var customSpeakerNames: [String: String]  // "speaker_0" -> "Pim"
    var moments: [Moment]      // user-added timestamps + notes
    var summary: Summary?      // cached LLM output
    // Computed: date, duration, speakerCount from transcript.json
}
```

`RecordingSession` gains: `@Published var marks: [TimeInterval] = []`, `func mark()`.

Wire `MenuBarExtra` to dismiss its popover via `@Environment(\.dismissWindow)` when the user clicks "Open Library" — and use `OpenWindowAction` to launch the Library window.

---

## Files in this bundle

- `Meeting.html` — open in a browser; canvas with all six surfaces
- `src/glass.jsx` — Liquid Glass primitives (Glass, GlassPill, TrafficLights). Reference for tint/blur/inset values.
- `src/icons.jsx` — inline SVG icon set used in the proto. **Replace with SF Symbols** in SwiftUI: mic.fill, record.circle.fill, stop.fill, pause.fill, magnifyingglass, plus, gearshape, folder, person.fill, person.2.fill, sparkles, chevron.down, chevron.right, checkmark, xmark, square.and.arrow.down, square.and.arrow.up, pin.fill, pencil, star.fill, clock.fill, calendar, bookmark.fill, waveform, speaker.wave.2.fill, eye.fill, lock.fill, etc.
- `src/menubar-popover.jsx` — popover idle/recording/transcribing
- `src/library.jsx` — three-pane library window
- `src/recording.jsx` — expanded recording window
- `src/transcript.jsx` — split transcript viewer
- `src/permissions.jsx` — onboarding + done toast
- `src/app.jsx` — composes all the above on the canvas

## What's intentionally not designed

Tell me if you need any of these and I'll add them:
- Settings window (audio device picker, model size, LLM provider toggle)
- Model download progress UI (first-run WhisperKit/SpeakerKit download)
- Share sheet detail
- Empty state for Library before first recording
- Error states beyond the existing `errorMessage`
- Light vs dark mode parity (the proto leans dark; SwiftUI should support both via `.colorScheme`)

## Existing project context

The Swift code lives in `Meeting/App/`, `Meeting/Capture/`, `Meeting/Transcribe/`. Read `CLAUDE.md` at the project root before touching anything — there are non-obvious gotchas around audio thread isolation, Sendable boxing, Electron multi-process taps, and `List(selection:)` deferral that you must preserve. The Xcode project is generated by **XcodeGen** — never hand-edit `Meeting.xcodeproj`. Run `xcodegen generate` after adding new files.

To prototype any of these views in isolation, drop them into a `#Preview` block. The `RecordingSession` and `TranscriptionSession` already work; you can build the new shell against them without touching the capture/transcribe layers.
