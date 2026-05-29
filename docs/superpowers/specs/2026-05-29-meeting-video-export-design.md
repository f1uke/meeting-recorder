# Meeting video export — design

Date: 2026-05-29

## Problem

A recorded meeting is stored as separate files: a silent screen recording
(`video.mov`, HEVC) plus two independent audio captures (`mic.m4a` = the user,
`output.m4a` = the meeting app, both AAC stereo 48 kHz), and a transcript
(`transcript.{json,md,srt}`). Opening `video.mov` plays no sound, and there is
no single artifact a user can hand to someone else.

We want one **Export** action that produces a single shareable `.mp4` containing
the picture, both audio streams, and the transcript as toggleable subtitles.

## Requirements

- Output: one `.mp4` file (H.264/HEVC video + AAC audio — both already
  mp4-compatible, so **no re-encode**; passthrough/remux only).
- Two **separate** audio tracks (not mixed): `output.m4a` added first (default
  track that plays), `mic.m4a` second. A player like QuickTime lets the viewer
  switch between them.
- Transcript embedded as a **soft subtitle track** (tx3g) that can be toggled
  on/off during playback. Each cue is prefixed with the speaker's display name
  (e.g. `Me: …`), matching the existing `.srt` convention.
- A/V sync: the audio files are already silence-padded to wall-clock time to
  match `video.mov` (see `ProcessAudioTap.swift:368-374`), so every track is
  inserted at `t = 0` with no offset compensation.

## Approach (chosen): single-pass AVAssetReader → AVAssetWriter

One `AVAssetWriter(fileType: .mp4)` fed by `AVAssetReader`s, one per source file.
All media is copied through without re-encoding (passthrough), while the
subtitle track is authored from the transcript.

Rejected alternative — `AVMutableComposition` + `AVAssetExportSession`: simpler
for muxing video + 2 audio, but there is no supported path to author a soft
tx3g subtitle track into a composition (no SRT→AVAsset), so it fails the
subtitle requirement.

## Components

### `Meeting/Transcribe/MeetingVideoExporter.swift` (new)

- `actor MeetingVideoExporter`
  - `func export(meeting folder: URL, subtitleNames: [SpeakerID: String]? , to destination: URL, progress: @Sendable (Double) -> Void) async throws`
  - Builds:
    - `AVAssetReader` for `video.mov` → 1 video track output, `outputSettings:
      nil` (compressed passthrough).
    - `AVAssetReader` for `output.m4a` and `mic.m4a` (each if present) → audio
      track outputs, passthrough.
    - `AVAssetWriter` (`.mp4`) with matching passthrough inputs
      (`outputSettings: nil`, `sourceFormatHint` from each source track). Video
      input added first, then audio output, then audio mic, then the subtitle
      input — track order in the file follows input add order.
    - Subtitle input: `AVAssetWriterInput(mediaType: .subtitle, outputSettings:
      nil, sourceFormatHint: <tx3g format desc>)`, fed by `TimedTextEncoder`.
  - Pumps each input via `requestMediaDataWhenReady(on:)` on a serial queue;
    reports progress as `videoSamplePTS / duration`; honors `Task.cancellation`.
- Errors: `MeetingVideoExporter.ExportError` (`.noVideo`, `.unreadable`,
  `.writerFailed(Error)`, `.cancelled`).

### `TimedTextEncoder` (in the same file, separate struct, unit-tested)

Pure transformation, no AVAssetWriter dependency in its core:

- `static func cues(from transcript: MergedTranscript, names: [SpeakerID: String]) -> [TimedTextCue]`
  - One cue per segment, `start..<end`, text = `"<name>: <segment text>"`.
  - Drops/zeroes cues with non-positive duration; clamps overlaps so cues are
    monotonic (a cue's start is raised to the previous cue's end if they
    overlap — tx3g cannot show two cues at once).
- `static func sampleData(for cue: TimedTextCue) -> Data` — tx3g sample payload:
  `[UInt16 big-endian text byte count][UTF-8 text bytes]`.
- `static func emptySampleData() -> Data` — a 0-length text sample (`00 00`)
  used to fill gaps so the subtitle track is contiguous (tx3g requires gapless
  coverage; gaps are filled with empty samples).
- The exporter wraps these into `CMSampleBuffer`s with the appropriate timing
  and the tx3g `CMFormatDescription`.

The tx3g `CMFormatDescription` construction (sample-description extension /
text box defaults) is the main implementation risk and is isolated behind a
single factory function so it can be iterated on without touching the pump
loop.

### UI integration

- `TranscriptViewerView` — repurpose the existing **Export** toolbar pill
  (`TranscriptViewerView.swift:278`, currently re-exports text formats) to run
  the video export. The **Share** pill (reveals the folder) stays.
- `LibraryView` — add the same action to the detail toolbar
  (`LibraryView.swift`, between "Reveal in Finder" and "Delete").
- Destination: `NSSavePanel`, default file name `<meeting title>.mp4`,
  allowed type `.mpeg4Movie`. On success, `activateFileViewerSelecting` reveals
  the new file in Finder.
- Speaker names passed to the exporter come from the meeting's resolved
  speaker display names (library overrides applied), falling back to
  `transcript.speakers`.

### Progress UX

A lightweight SwiftUI sheet with an indeterminate-to-determinate progress bar
and a **Cancel** button, driven by an `@MainActor` `ExportState` (`.idle`,
`.running(Double)`, `.failed(String)`). The export runs in a `Task`; cancelling
the task tears the writer down and deletes the partial file. Runs off the main
actor (the exporter is an `actor`).

## Edge cases / error handling

- No `video.mov` → Export button disabled (audio-only meetings out of scope).
- Missing `mic.m4a` or `output.m4a` → include whichever audio files exist; skip
  the absent track. (At least one is expected.)
- No transcript → export succeeds with no subtitle track.
- Subtitle authoring failure (tx3g format-description / append error) →
  degrade gracefully: log and finish the export with video + audio only,
  rather than failing the whole export.
- Codec not mp4-compatible (not expected with HEVC/AAC) → throw `.writerFailed`;
  transcode fallback is explicitly out of scope this round and logged.
- Destination already exists → `NSSavePanel` handles the overwrite prompt; the
  exporter removes a stale file at the path before writing.

## Testing

- Unit tests (`MeetingTests`):
  - `TimedTextEncoder.cues` — segment→cue mapping, speaker-name prefix, overlap
    clamping, zero-duration handling.
  - `TimedTextEncoder.sampleData` — correct big-endian length prefix + UTF-8
    body for ASCII and Thai text; empty-sample bytes.
- Manual/integration: export a real meeting, open in QuickTime — confirm two
  selectable audio tracks (output is default), subtitles toggle on/off and read
  correctly (incl. Thai), and audio stays in sync with video to the end.

## Out of scope

- Mixing the two audio streams into one track (left/right split, ducking).
- Burned-in (hard) subtitles.
- Transcode fallback for non-mp4-compatible source codecs.
- Native share-sheet (AirDrop/LINE) hand-off after export — reveal in Finder
  for now.
