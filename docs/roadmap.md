# Roadmap

Future work that is not yet scheduled. Move items into a branch / PR when picked up.

## Cross-meeting speaker identity

**Problem.** Today `speaker_0`, `speaker_1`, … are scoped to a single diarization run. SpeakerKit clusters embeddings inside one `output.wav` and labels them by first-seen order, so `speaker_0` in meeting A and `speaker_0` in meeting B are unrelated. Users have to rename speakers per-meeting via `customSpeakerNames` in `library.json`.

**Goal.** Recognize the same person across meetings so renaming once propagates, and the Library can show "person X attended N meetings".

**Sketch.**
1. Persist a centroid embedding per identified speaker in a Library-level store (e.g. `~/Library/Application Support/dev.fluke.meeting/speakers.json` or a small SQLite). Each identity = `{id, displayName, centroid: [Float], sampleCount, sourceMeetingIDs}`.
2. After SpeakerKit clustering on a new meeting, take each cluster's mean embedding and match against the store via cosine distance with a conservative threshold (start ~0.5 — tighter than pyannote's 0.6 cluster threshold to avoid false merges across different voices).
3. On match: reuse existing identity ID and update the centroid (running mean weighted by sampleCount). On miss: mint a new identity. Update `MergedTranscript` so `speaker` field references the global ID, with the per-meeting `speaker_N` kept as a fallback.
4. UX in Transcript Viewer's Speakers card: show match confidence, let user confirm / split / merge identities. Renames flow back to the global store, not just `library.json`.
5. Library sidebar: new "People" group listing identities with meeting counts.

**Open questions.**
- Where does SpeakerKit expose per-cluster mean embeddings? May need to compute ourselves from segment-level embeddings if not surfaced.
- Privacy / reset story — embeddings are biometric-ish; need an "Forget person" action and a global wipe.
- Migration: existing meetings have `speaker_N` IDs only. Lazy-backfill on next open, or one-time migration sweep.

**Captured.** 2026-04-30 — flagged during discussion of why Speaker 11 in meeting A ≠ Speaker 11 in meeting B.

## Whole-screen recording mode

**Problem.** Today `RecordingSession.start(window:)` accepts a single `SCWindow`, which forces the user to pick one app even when the meeting spans multiple windows (e.g. Discord voice + Keynote screenshare, or a Meet tab + a separate IDE the team is reviewing). `ProcessAudioTap` is wired to one app's audio and `MicGate` watches one app's mic toggle — both single-target by design.

**Goal.** Add an opt-in whole-screen mode: capture an entire `SCDisplay` (not a single window), tap system-wide audio, and run a `MicGate` per supported app concurrently with merged muted intervals. The existing single-window mode stays untouched — this is purely additive.

**Sketch.**

1. **Recording target abstraction.** New `enum RecordingTarget { case window(SCWindow); case display(SCDisplay) }`. `RecordingSession.start(target:event:)` switches on it. `ScreenCaptureCoordinator.start(target:videoURL:)` builds either `SCContentFilter(desktopIndependentWindow:)` (existing) or `SCContentFilter(display:excludingApplications:[Meeting.app self], exceptingWindows:[])` for the display variant. `WindowPicker` grows a "Whole screen" section above the window list, listing every `SCShareableContent.displays`.

2. **System-wide audio tap.** Add `enum TapMode { case perApp(pid, bundleID); case systemWide }` to `ProcessAudioTap`. `.systemWide` swaps `CATapDescription(stereoMixdownOfProcesses:)` for `CATapDescription(stereoGlobalTapButExcludeProcesses: [selfAudioObject])`. Self-exclusion is required to prevent the app's own toast / popover preview audio from feeding back into `output.m4a`. Resolve the self `AudioObjectID` via `kAudioHardwarePropertyTranslatePIDToProcessObject` on the current `getpid()`. Document the diarization caveat: Spotify / system sounds will pollute output.m4a and SpeakerKit may surface them as pseudo-speakers — accept it for v1; an excludable-bundles list is Phase 6.

3. **Multi-app MicGate coordinator.** Refactor `MicGate` (single detector) into a `MicGateCoordinator` that owns N `AXMicButtonDetector`s — one per supported bundle that is currently running (scan `NSWorkspace.shared.runningApplications`). Merge semantic is **AND**, not OR: `aggregateMuted = active_detectors.allSatisfy { $0.lastKnownActive == false }`. *Active* means the detector has located its button at least once — detectors that never found one (`lastKnownActive == nil`) contribute no opinion. Open mute interval on aggregate `false→true`, close on `true→false`. The AND choice is deliberate: if user is muted in Meet but unmuted in Discord, they may be talking in Discord, and gating Discord audio out of the transcript would lose that conversation. Single-window mode keeps single-detector behavior — multi-mode is gated to the `.display` recording target.

4. **`mic_gate.json` schema.** Top-level `muted` stays as merged intervals (consumer `TranscriptionSession` unchanged). Add optional `perSource: { "Meet": [intervals], "Discord": [intervals] }` for debugging. Keep `version: 1` — additive optional field doesn't need a bump.

5. **UI updates.** `MenuBarLabel`: 1 detector → unchanged. ≥2 detectors → aggregate icon (slash if all-muted, fill if any-active) + tooltip listing each source's state. `RecordingWindowView` / `PopoverRecordingView`: per-detector chips showing 🟢 active / 🔴 muted / 🟡 lost.

6. **Loose ends.** `MeetParticipantsCollector` currently gated on `bundleID == "com.google.Chrome"` — relax to "Chrome is running + AX trusted" so it also runs in display mode when a Meet tab is open in the background. `currentSourceTitle` / `currentSourceApp` for display mode → fall back to `"Whole screen — \(display.localizedName)"` or the attached calendar event title.

**Open questions.**
- Display picker UX with multi-monitor setups — show all displays in the picker, or default to main display only?
- `mic_gate.json` schema bump (v1 → v2) once we add `perSource`, or keep flat and stash debug elsewhere? Leaning flat + optional field.
- Default exclude list for system-wide tap (Spotify / Music / Messages) — Phase 2 or Phase 6? Phase 6 keeps Phase 2 minimal but means v1 of the feature ships with noticeable diarization noise.
- Multi-detector CPU cost: N AX polls × 200 ms in parallel — needs a quick measurement on a hot machine before committing to "always run all supported detectors". Probably <1 % but verify.

**Risks.**
- `stereoGlobalTapButExcludeProcesses` is documented from macOS 14.2 but unverified on this codebase's macOS 15 deployment target — first thing to probe in Phase 2 before refactoring.
- Diarization quality drops in display mode (system mix). User-visible caveat — surface it in the UI when display target is picked.

**Test plan.**
- Extend `tools/mic-gate-probe/probe.swift` to multi-target — run Meet + Discord concurrently, log aggregate.
- Unit tests for `MicGateCoordinator.merge`: both muted → muted; one muted one active → active; one found one lost → follows the found; none found → no gating.
- Manual: record whole-screen with Meet + Discord both joined, verify `output.m4a` carries both, `mic_gate.json.muted` matches the AND of mute toggles, document Spotify-leak behavior.

**Captured.** 2026-05-07 — after verifying Discord MicGate detection works (probe shipped same day), user requested the whole-screen extension with system-wide tap + merged multi-gate.
