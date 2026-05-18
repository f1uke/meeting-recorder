# Meeting

Native macOS app that records a meeting window (or a full display) plus the **mic and the meeting app's process-level audio as separate streams**, then runs local WhisperKit + SpeakerKit (or a cloud engine) to produce a speaker-labelled transcript and a markdown meeting note.

The point of capturing per-process audio rather than the whole desktop mix is so diarization can split meeting participants without picking up Spotify, system notifications, or other apps.

## Download

Grab the latest **`.dmg`** or **`.zip`** from the [Releases page](https://github.com/f1uke/meeting-recorder/releases/latest). The app is signed but not notarized — the first launch needs **right-click → Open** to clear Gatekeeper. Requires macOS 15 Sequoia or later (Apple Silicon and Intel; universal binary).

## Features

### Capture
- **Window-scoped or full-display video** via `SCStream` with an `SCContentFilter` — pick any window from any app, or capture an entire display when you need multiple apps in one shot
- **Per-process audio tap** using `CATapDescription` + a private aggregate device — captures only the chosen meeting app, even Electron-based apps (Discord, Slack, Teams, VS Code Live Share) whose audio lives in helper PIDs
- **Mic gating for Meet and Discord** — detects when you've muted yourself in the meeting UI and drops those intervals from the transcript so they aren't re-spoken on top of others
- **Mic preprocessing** — acoustic echo cancellation, loudness normalization, and silence-trimming applied in memory before the transcription pass (the raw `mic.m4a` file on disk is preserved untouched)
- **Live recording window** with 96-bar dual-stream waveforms, a running mark list, and ⌘B mark-this-moment
- **Recording context** — captures URLs visited in Safari/Chrome/Arc/Edge/Brave, clipboard text/links/images, and Jira card metadata so they can be folded into the meeting note

### Transcription
- **Speaker-labelled transcripts** via WhisperKit (`large-v3`) + SpeakerKit, tuned for Thai-English code-switching meetings
- **Multiple transcription engines**: local (free, private), Google Gemini (2.5 Pro / Flash / Flash-Lite, with optional Batch API for 50% off), OpenAI (`whisper-1`, `gpt-4o-transcribe`, `gpt-4o-transcribe-diarize`)
- **Voiced-aware chunking** — cloud-provider audio is sliced at sentence pauses (not fixed time windows), uploaded in parallel, and silent chunks below −40 dBFS are skipped
- **Background transcription queue** — kick off a new recording while previous meetings are still transcribing; Gemini batch jobs survive app restarts via polling persistence
- **Domain glossary editor** primes cloud system prompts so technical terms ("Kubernetes", "GitLab", "gRPC") survive Thai-leaning transcription

### Speakers
- **Inline rename + click-to-jump** in the transcript viewer; renames write through to every cached meeting that references the speaker
- **Calendar-aware attendee pool** — drag-and-drop label any voice with the actual attendee from the EventKit invite, with group expansion for distribution lists
- **Meet attendee scraping** — reads the participant tiles in Google Meet via Accessibility APIs so the attendee suggestions reflect who actually joined, not just who was invited
- **Cross-meeting speaker identity** — pyannote v3 Core ML embeddings extracted per segment and matched against a rolling identity store; suggests "this is probably Alice from last week's meeting" when speakers reappear

### Notes and summaries
- **AI summary + action items** via the Claude Code CLI (`claude -p`), with the prompt requiring the model to actually read every captured image, Jira card, and Confluence page before writing
- **Markdown meeting note** rendered locally from the cached summary — Confluence-template friendly (🎯 Goals, emoji-prefix headers), with mermaid diagrams and LLM-curated reference links
- **Action-item highlights** in the transcript viewer — click any action item to jump to the moment it was discussed
- **Obsidian sync** — point Settings at an Obsidian vault folder to drop the rendered note straight into your notes graph

### Library
- **Three-pane browser** grouped by Today / Yesterday / This week / Earlier with search, tags, star, and storage usage
- **Transcript viewer** with synced AVPlayer, search-aware diarized segments, marked moments, speaker samples, and Quick Look previews for captured screenshots
- **Per-meeting overrides** — titles, tags, custom speaker names persist in `library.json` separate from the immutable raw recording

## Requirements

- macOS 15 (Sequoia) or later
- Xcode 16+ with the Swift 6 toolchain
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) — `brew install xcodegen`
- ~5 GB free disk for WhisperKit `large-v3` + SpeakerKit weights (downloaded on first run to `~/Library/Application Support/dev.fluke.meeting/Models/`)
- Optional: a Gemini or OpenAI API key for cloud transcription
- Optional: the [Claude Code CLI](https://claude.com/claude-code) for AI summaries

## Setup

```bash
xcodegen generate
open Meeting.xcodeproj
```

The first build prompts for Screen Recording, Microphone, and Audio Capture permission. Calendar and AppleEvents are requested lazily on first use.

`project.yml` hardcodes a Personal Team development certificate (`DEVELOPMENT_TEAM: 49AUFL5Q3U`). Change it to your own team ID before building — otherwise signing will fail.

## Build

```bash
# Build with stable Personal-Team signing (matches Xcode — required for the
# running app to keep TCC permissions across rebuilds):
xcodebuild -project Meeting.xcodeproj -scheme Meeting -configuration Debug \
  -destination 'platform=macOS' build

# Run all tests:
xcodebuild -project Meeting.xcodeproj -scheme Meeting -configuration Debug \
  -destination 'platform=macOS' test
```

After adding or moving Swift files, or after editing `project.yml`, run `xcodegen generate` again.

## Privacy

- **Local engine** — nothing leaves the device. Transcription, speaker diarization, and cross-meeting identity embeddings all run on your Mac.
- **Cloud engines** (Gemini / OpenAI) — audio is uploaded to the chosen provider for transcription only. API keys are stored in macOS preferences for now (Keychain migration is planned).
- **AI summary** — shells out to the Claude Code CLI, which sends the transcript markdown plus any captured context (URLs, clipboard text, Jira card payloads) to Anthropic. Gated behind a one-time disclosure dialog.
- **Calendar, browser, clipboard, and identity data** stay on your Mac. The browser-URL watcher uses NSAppleScript to read the front-tab URL of supported browsers (Safari, Chrome, Arc, Edge, Brave) during a recording; the clipboard watcher snapshots text/links/images you copy. Both feed `context.json` for the meeting and only leave the device if you generate an AI summary. The cross-meeting identity store lives at `~/Library/Application Support/dev.fluke.meeting/`.
- **Obsidian sync** — if you point Settings at a vault folder, the rendered markdown note is written to disk there; no network calls.

## Architecture

Seven layers under `Meeting/`:

- `Capture/` — `RecordingSession` orchestrating `ScreenCaptureCoordinator` (window or display), `MicRecorder`, `ProcessAudioTap`, `BrowserURLWatcher`, `ClipboardWatcher`, `MicGate`, and `MeetParticipantsScraper`
- `Transcribe/` — `TranscriptionProvider` protocol with `LocalProvider` (WhisperKit + SpeakerKit), `GeminiProvider` (incl. Batch API), and `OpenAIProvider`. Plus `TranscriptionQueue` (background queue), `AudioPreprocessor` (AEC + loudness), `CloudAudioPrep` (voiced-aware chunking), `MeetingNoteRenderer`, and `LLMProvider` / `ClaudeCLIProvider` for AI summaries
- `Identity/` — cross-meeting speaker identity: `SpeakerEmbedder` (pyannote v3 Core ML), `EmbeddingExtractionQueue`, `IdentityStore` (running-mean centroids), and `IdentityMatcher` (weighted composite score with greedy mutual exclusion)
- `Calendar/` — EventKit wrapper: store, matcher (current meeting), notifier, and the calendar "now" card surfaced in the popover
- `Library/` — file-system-watched index of `~/Documents/Meetings/`, with overrides (titles, tags, custom speaker names) layered on top via `library.json`
- `Theme/` — Liquid Glass design system that picks up Tahoe glass on macOS 26 and degrades to classic vibrancy on macOS 15
- `App/` — `MenuBarExtra` shell, four scenes (popover, recording window, library, transcript viewer), permissions, toast, settings

Per-meeting artifacts land at `~/Documents/Meetings/<yyyy-MM-dd_HH-mm-ss>/`: `video.mov`, `mic.m4a`, `output.m4a`, `transcript.{json,md}`, plus (when generated) `summary.json`, `context.json`, `embeddings.json`, `meet_participants.json`, `mic_gate.json`, and `speakers.json`. The markdown meeting note is rendered on demand from these and not persisted.

See [`CLAUDE.md`](./CLAUDE.md) for the full architecture notes and project-specific gotchas (Swift 6 audio-thread isolation, Electron multi-process taps, etc.).

## License

[MIT](./LICENSE) © 2026 Fluke Sattra
