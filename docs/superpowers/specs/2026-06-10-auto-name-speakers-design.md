# Auto-name speakers above a confidence threshold

**Date:** 2026-06-10
**Status:** Approved (design)

## Summary

After a meeting is transcribed, automatically apply a speaker's suggested
identity name when the matcher's confidence is at or above a user-configurable
threshold (default **80%**). Auto-applied names are visually badged and
one-click revertible. Lower-confidence matches keep behaving as today (manual
suggestions surfaced for the user to accept). The whole feature has its own
on/off toggle, ON by default.

## Motivation

The app already computes a confidence-scored identity suggestion for every
diarized speaker (`IdentityMatcher` → `IdentitySuggestion.confidencePercent`,
50–99%). Today those only surface as manual suggestions the user clicks to
accept. For recurring participants whose voice is already known, that click is
pure friction — the match is effectively certain. Auto-applying high-confidence
matches removes that step while staying safe (badged + revertible) so the user
can always see and undo what the machine decided.

## What this builds on (already exists)

- `IdentityMatcher` scores each diarized speaker against known identities (voice
  embedding centroid, calendar attendees, Meet participant names, recency) and
  produces an `IdentitySuggestion` with `score: Double` (0–1) and
  `confidencePercent: Int` (50–99). Lives in `Meeting/Identity/`.
- `MeetingsLibrary.updateSpeaker(meeting:speakerID:refresh:transform:)` +
  `speakers.json` (`SpeakerProfile` in `SpeakerMapFile.swift`) is the write path
  for a speaker's name. `linkOrCreateIdentity(...)` folds a named speaker's voice
  embedding into the global identity store.
- `AppPreferences` (`Meeting/App/AppPreferences.swift`) already hosts
  `identitySuggestionsEnabled` and `identityMinSuggestScore`, persisted via
  UserDefaults with `didSet`.
- `SettingsView.IdentityMatchingSection` (`Meeting/App/SettingsView.swift`)
  already renders the manual-suggestion toggle + threshold slider — the new
  controls slot in directly beside them.
- `AppState.stopAndTranscribe()` is the post-recording flow
  (stop → rescan → transcribe → rescan → toast) — the natural place to trigger
  the auto-apply pass.

## Components and changes

### 1. `SpeakerProfile` (`Meeting/Library/SpeakerMapFile.swift`)

Add one stored field plus a computed convenience:

- `autoNamedConfidence: Int?` — the `confidencePercent` at the time of
  auto-apply, shown in the badge (`✨ auto 92%`). `nil` means the speaker was
  not auto-named.
- `autoNamed: Bool` (computed) — `autoNamedConfidence != nil`. Used to render the
  badge and gate the revert action.

Keeping the single persisted field **optional** means existing `speakers.json`
files (which lack the key) decode unchanged via synthesized Codable — no custom
decoder needed. A speaker the user renamed by hand has `autoNamedConfidence ==
nil` and is never touched by the pass.

### 2. `AppPreferences` (`Meeting/App/AppPreferences.swift`)

Add two preferences following the existing pattern (`@Published` + `didSet`
UserDefaults sync + `Keys` enum entries + `init()` load with default):

- `autoNameSpeakersEnabled: Bool` — default `true`.
- `autoNameThreshold: Double` — default `0.80`, valid range `0.60…0.95`.

The threshold is stored as a 0–1 fraction but is compared in the UI's percent
space: a speaker is auto-named when
`suggestion.confidencePercent >= Int(autoNameThreshold * 100)`. This keeps the
setting in the same percentage the user sees on the suggestion chip, avoiding a
score-vs-percent mismatch. (Note: `confidencePercent` only exists for
suggestions whose raw score already cleared `minSuggestScore`, so the comparison
is well-defined.)

### 3. `SettingsView.IdentityMatchingSection` (`Meeting/App/SettingsView.swift`)

Below the existing "Suggest speakers from past meetings" toggle + threshold
slider, add:

- A `Toggle` bound to `autoNameSpeakersEnabled` — label "Auto-name when
  confident".
- A `Slider` bound to `autoNameThreshold` (`0.60…0.95`, step `0.05`), displayed
  as a percentage, enabled only when the toggle is on.

```
Identity matching
─────────────────────────
[✓] Suggest speakers from past meetings
     Suggestion threshold  ──●──  (45%)
[✓] Auto-name when confident
     Auto-name threshold   ────●  (80%)
```

### 4. Auto-apply pass — `MeetingsLibrary.autoNameSpeakers(meeting:)`

New method (with a `nonisolated static` pure helper for testability, matching the
existing `MeetingsLibrary` factoring of side-effect methods from pure selection
logic). Logic:

1. Guard `AppPreferences.autoNameSpeakersEnabled`; no-op if off.
2. Obtain the identity suggestions for the meeting's speakers (reuse the existing
   matcher path that already runs during library scan — no new scoring).
3. For each speaker that is **still on its default name** (`Speaker N`, i.e. no
   user-set custom `displayName` and `autoNamed == false`):
   - If its top suggestion's `confidencePercent >= Int(autoNameThreshold * 100)`,
     apply it via `updateSpeaker(...)`: set `displayName` to the identity name,
     `autoNamed = true`, `autoNamedConfidence = confidencePercent`.
   - Then call `linkOrCreateIdentity(...)` for that speaker, exactly as a manual
     accept does.
4. The matcher's existing greedy mutual-exclusion guarantees two speakers can't
   be assigned the same identity in one pass.

The pure helper takes the speakers, their suggestions, the threshold, and the
enabled flag, and returns the list of `(speakerID, name, confidence)` to apply —
so it can be unit-tested without disk or UI.

### 5. Trigger (`AppState.stopAndTranscribe()`)

Call `autoNameSpeakers(meeting:)` once in the post-transcription flow, after
transcription completes and embeddings/suggestions are available (i.e. after the
rescan that follows transcription), before the success toast. Runs once per
meeting; it does not re-fire on later library scans.

### 6. UI badge + revert (`Meeting/Transcribe/TranscriptViewerView.swift`)

In the speakers panel, when `profile.autoNamed`:

- Render a subtle chip next to the name: `✨ auto NN%` (using
  `autoNamedConfidence`).
- Add a **Revert** action that resets the speaker to its default `Speaker N`
  name, clears `autoNamed` / `autoNamedConfidence`, and unlinks the auto-applied
  identity association (mirroring the existing rename → updateSpeaker path).

```
Speakers
──────────────────
Me
Somchai     ✨ auto 92%   [revert]
Speaker 2   suggest: Nok 71%  [accept]
```

## Safety rules

- Never overwrites a manually-set name (only speakers still on their default
  `Speaker N` name are eligible).
- Only ever *applies* a name; never auto-*renames* an already-named speaker.
- Greedy mutual-exclusion (existing matcher behavior) prevents duplicate
  identity assignment.
- When `autoNameSpeakersEnabled` is off, the pass is a no-op and behavior is
  exactly as today.
- Auto-applied names are always badged and revertible — nothing the machine
  decides is hidden from the user.

## Practical note

An 80% confidence match in practice requires a strong **voice-embedding** match
to a previously-named identity; the Meet-name (0.10) and calendar (0.20) priors
alone cannot reach 80%. So auto-naming mostly activates for recurring people
whose voice the app has already learned — the intended behavior.

## Testing

Unit tests on the pure auto-apply helper (no disk/UI):

- Applies a name when `confidencePercent >= threshold`.
- Skips when below threshold.
- Skips speakers that already have a user-set (manual) name.
- No-ops entirely when the feature toggle is off.
- Sets `autoNamed = true` and `autoNamedConfidence` to the suggestion's percent.
- Revert restores the default `Speaker N` name and clears the auto fields.

## Out of scope

- Retroactive re-application across older meetings when an identity is later
  named (considered and rejected — too surprising).
- Auto-naming the local mic speaker ("Me" is already fixed).
- Any change to how suggestions are *scored*; this feature only consumes existing
  scores.
