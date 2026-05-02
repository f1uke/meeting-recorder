# Meeting

Native macOS app that records a meeting window's video plus the **mic and the meeting app's process-level audio as separate streams**, then runs local WhisperKit + SpeakerKit (or a cloud engine) to produce a speaker-labelled transcript.

The point of capturing per-process audio rather than the whole desktop mix is so diarization can split meeting participants without picking up Spotify, system notifications, or other apps.

## Features

- **Window-scoped video** via `SCStream` with an `SCContentFilter` that targets a single window
- **Per-process audio tap** using `CATapDescription` + a private aggregate device — captures only the chosen meeting app, even Electron-based apps (Discord, Slack, Teams, VS Code Live Share) whose audio lives in helper PIDs
- **Speaker-labelled transcripts** via WhisperKit (`large-v3`) + SpeakerKit, tuned for Thai-English code-switching meetings
- **Multiple transcription engines**: local (free, private), Google Gemini (2.5 Pro / Flash / Flash-Lite, with optional Batch API for 50% off), OpenAI (`whisper-1`, `gpt-4o-transcribe`, `gpt-4o-transcribe-diarize`)
- **Domain glossary** primed into cloud system prompts so technical terms ("Kubernetes", "GitLab", "gRPC") survive Thai-leaning transcription
- **AI summary + action items** via the Claude Code CLI (`claude -p`)
- **Markdown meeting notes** generated from transcript + summary, ready to paste into your knowledge base
- **Live recording window** with 96-bar dual-stream waveforms and ⌘B mark-this-moment
- **Library** with grouped (Today / Yesterday / This week / Earlier) view, search, tags, and a transcript viewer that scrubs the video to any segment
- **Calendar awareness** — pre-fills meeting titles and attendees from EventKit
- **Browser context** — captures URLs you visit during a recording so they're folded into the AI summary

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

- **Local engine** — nothing leaves the device. Transcription and speaker diarization both run on your Mac.
- **Cloud engines** (Gemini / OpenAI) — audio is uploaded to the chosen provider for transcription only. API keys are stored in macOS preferences for now (Keychain migration is planned).
- **AI summary** — shells out to the Claude Code CLI, which sends the transcript markdown to Anthropic. Gated behind a one-time disclosure dialog.
- **Calendar and browser data** stay on your Mac. The browser-URL watcher uses NSAppleScript to read the front-tab URL of supported browsers (Safari, Chrome, Arc, Edge, Brave); URLs only leave the device if you generate an AI summary.

## Architecture

Five layers under `Meeting/`:

- `Capture/` — `RecordingSession` orchestrating `ScreenCaptureCoordinator`, `MicRecorder`, and `ProcessAudioTap`
- `Transcribe/` — `TranscriptionProvider` protocol with local (WhisperKit + SpeakerKit) and cloud (Gemini, OpenAI) implementations, plus `LLMProvider` for AI summaries
- `Library/` — file-system-watched index of `~/Documents/Meetings/`, with overrides (titles, tags, custom speaker names) layered on top via `library.json`
- `Theme/` — Liquid Glass design system that picks up Tahoe glass on macOS 26 and degrades to classic vibrancy on macOS 15
- `App/` — `MenuBarExtra` shell, four scenes (popover, recording window, library, transcript viewer), permissions, toast

Per-meeting artifacts land at `~/Documents/Meetings/<yyyy-MM-dd_HH-mm-ss>/`: `video.mov`, `mic.wav`, `output.wav`, `transcript.{json,md,srt}`, `marks.json`, optionally `summary.json`.

See [`CLAUDE.md`](./CLAUDE.md) for the full architecture notes and project-specific gotchas (Swift 6 audio-thread isolation, Electron multi-process taps, etc.).

## License

[MIT](./LICENSE) © 2026 Fluke Sattra
