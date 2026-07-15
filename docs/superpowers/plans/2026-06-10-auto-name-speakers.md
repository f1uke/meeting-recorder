# Auto-name Speakers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Automatically apply a diarized speaker's suggested identity name when the matcher's confidence is at or above a user-configurable threshold (default 80%), with a visible badge and one-click revert.

**Architecture:** Reuse the existing `IdentityMatcher` → `IdentitySuggestion` pipeline. A pure selection helper picks which suggestions clear the threshold; an apply pass writes them to `speakers.json` via the existing `applyIdentitySuggestion` path, tagging each with its confidence. The pass is triggered once per meeting when its acoustic embeddings finish extracting (the moment suggestions first become computable), so it runs right after transcription and never re-writes a meeting on later scans.

**Tech Stack:** Swift 6 / SwiftUI, XcodeGen, XCTest. macOS 15 target.

---

## Background (read before starting)

The app already scores each un-named diarized speaker against known cross-meeting
identities and produces `IdentitySuggestion` values (`Meeting/Identity/IdentitySuggestion.swift`):

```swift
struct IdentitySuggestion: Hashable, Sendable, Identifiable {
    let speakerID: SpeakerID
    let identityID: String
    let identityDisplayName: String
    let score: Double          // 0–1 composite
    let confidencePercent: Int // 50–99, mapped from score
    var id: String { "\(speakerID.rawValue):\(identityID)" }
}
```

Today these only render as manual "accept/reject" chips in the Transcript Viewer.
Key existing pieces this plan builds on:

- `IdentityMatcher.match(...)` (`Meeting/Identity/IdentityMatcher.swift`) returns at
  most one suggestion per speaker (greedy mutual exclusion), only for speakers that
  are still un-named.
- `MeetingsLibrary.loadRecord()` (`Meeting/Library/MeetingsLibrary.swift:600-644`)
  computes `MeetingRecord.identitySuggestions` during a scan, only for speakers whose
  `displayName` is still a default (`speaker_N` / `Speaker N` / `unknown`) and whose
  `identityID == nil`.
- `MeetingsLibrary.applyIdentitySuggestion(_:meeting:)` (`MeetingsLibrary.swift:373-397`)
  is exactly the "accept a suggestion" write path: updates the identity centroid, then
  writes `displayName` + `identityID` (+ email) to `speakers.json`.
- `EmbeddingExtractionQueue` (`Meeting/Identity/EmbeddingExtractionQueue.swift`) extracts
  per-speaker voice embeddings after transcription and writes `embeddings.json`. It is
  enqueued from `TranscriptionQueue.markDone()` (`Meeting/Transcribe/TranscriptionQueue.swift:505`).
  It currently has **no per-meeting completion callback** — this plan adds one.
- `SpeakerProfile` (`Meeting/Library/SpeakerMapFile.swift`) is the per-speaker record in
  `speakers.json`. All its optional fields decode cleanly from old files via synthesized
  Codable; the new field is added as an **optional** to preserve that.
- Default speaker name format is `"Speaker \(diarizedIndex + 1)"`, where `diarizedIndex`
  is parsed by `TranscriptMerger.diarizedIndex(_:)` (`Meeting/Transcribe/TranscriptMerger.swift:137`).

---

## File Structure

| File | Change | Responsibility |
|------|--------|----------------|
| `Meeting/Library/SpeakerMapFile.swift` | Modify | Add `autoNamedConfidence: Int?` + computed `autoNamed` to `SpeakerProfile` |
| `Meeting/App/AppPreferences.swift` | Modify | Add `autoNameSpeakersEnabled` + `autoNameThreshold` prefs |
| `Meeting/Library/MeetingsLibrary.swift` | Modify | Add pure `autoNameSelections(...)` helper, `autoNameSpeakers(folder:)`, `revertAutoName(...)`; extend `applyIdentitySuggestion` with `autoConfidence` |
| `Meeting/Identity/EmbeddingExtractionQueue.swift` | Modify | Add `onMeetingEmbedded` per-meeting completion callback |
| `Meeting/App/AppState.swift` | Modify | Wire `onMeetingEmbedded` → rescan + `autoNameSpeakers` |
| `Meeting/App/SettingsView.swift` | Modify | Add auto-name toggle + threshold slider to `IdentityMatchingSection` |
| `Meeting/Transcribe/TranscriptViewerView.swift` | Modify | Render `✨ auto NN%` badge + Revert under auto-named speakers |
| `MeetingTests/AutoNameSpeakersTests.swift` | Create | Unit tests for the pure selection helper + backward-compat decode |

---

### Task 1: `SpeakerProfile` — auto-name metadata field

**Files:**
- Modify: `Meeting/Library/SpeakerMapFile.swift:17-58`

- [ ] **Step 1: Add the stored field, computed flag, and init parameter**

In `SpeakerMapFile.swift`, add the new property to `SpeakerProfile` right after
`identityID` (line 34) and a computed `autoNamed`:

```swift
    var identityID: String?
    /// Set when the auto-name pass applied this speaker's name automatically
    /// (confidence ≥ the user's threshold). Holds the `confidencePercent` at
    /// the moment of auto-apply so the UI can show "✨ auto NN%". `nil` for
    /// manually-named or un-named speakers. Optional so old `speakers.json`
    /// files (which lack the key) still decode via synthesized Codable.
    var autoNamedConfidence: Int?

    /// Convenience: this speaker's name was applied automatically, not by hand.
    var autoNamed: Bool { autoNamedConfidence != nil }
```

Then extend the memberwise `init` (lines 36-50) to take and assign it:

```swift
    init(
        id: SpeakerID,
        displayName: String,
        attendeeId: String? = nil,
        email: String? = nil,
        role: String? = nil,
        identityID: String? = nil,
        autoNamedConfidence: Int? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.attendeeId = attendeeId
        self.email = email
        self.role = role
        self.identityID = identityID
        self.autoNamedConfidence = autoNamedConfidence
    }
```

- [ ] **Step 2: Build to verify it compiles**

Run:
```bash
xcodebuild -project Meeting.xcodeproj -scheme Meeting -configuration Debug \
  -destination 'platform=macOS' CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Meeting/Library/SpeakerMapFile.swift
git commit -m "SpeakerProfile: add autoNamedConfidence for auto-named speakers"
```

---

### Task 2: AppPreferences — auto-name toggle + threshold

**Files:**
- Modify: `Meeting/App/AppPreferences.swift:146-148` (after `identityMinSuggestScore`), `:239-241` (init), `:309-310` (Keys)

- [ ] **Step 1: Add the two `@Published` preferences**

In `AppPreferences.swift`, immediately after the `identityMinSuggestScore` property
(ends line 148), add:

```swift
    /// Master toggle for auto-naming high-confidence speakers. ON by default.
    /// Has effect only while `identitySuggestionsEnabled` is also on (the matcher
    /// must run to produce suggestions to auto-apply).
    @Published var autoNameSpeakersEnabled: Bool {
        didSet { UserDefaults.standard.set(autoNameSpeakersEnabled, forKey: Keys.autoNameSpeakersEnabled) }
    }

    /// A speaker is auto-named when its top suggestion's `confidencePercent`
    /// is ≥ `Int(autoNameThreshold * 100)`. Default 0.80 (80%). Settings exposes
    /// 0.60 … 0.95 in 0.05 steps.
    @Published var autoNameThreshold: Double {
        didSet { UserDefaults.standard.set(autoNameThreshold, forKey: Keys.autoNameThreshold) }
    }
```

- [ ] **Step 2: Load them in `init()`**

After the `identityMinSuggestScore` load (lines 240-241), add:

```swift
        self.autoNameSpeakersEnabled = (UserDefaults.standard.object(forKey: Keys.autoNameSpeakersEnabled) as? Bool) ?? true
        let storedAutoThreshold = UserDefaults.standard.object(forKey: Keys.autoNameThreshold) as? Double
        self.autoNameThreshold = storedAutoThreshold ?? 0.80
```

- [ ] **Step 3: Add the UserDefaults keys**

In the `private enum Keys` block, after `identityMinSuggestScore` (line 310), add:

```swift
        static let autoNameSpeakersEnabled = "dev.fluke.meeting.autoNameSpeakersEnabled"
        static let autoNameThreshold = "dev.fluke.meeting.autoNameThreshold"
```

- [ ] **Step 4: Build to verify**

Run:
```bash
xcodebuild -project Meeting.xcodeproj -scheme Meeting -configuration Debug \
  -destination 'platform=macOS' CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add Meeting/App/AppPreferences.swift
git commit -m "AppPreferences: add autoNameSpeakersEnabled + autoNameThreshold"
```

---

### Task 3: Pure selection helper + tests (TDD)

This is the testable core: given suggestions + current profiles + the toggle + the
threshold percent, return which suggestions to auto-apply. No disk, no UI.

**Files:**
- Create: `MeetingTests/AutoNameSpeakersTests.swift`
- Modify: `Meeting/Library/MeetingsLibrary.swift` (add `nonisolated static` helpers)

- [ ] **Step 1: Write the failing test file**

Create `MeetingTests/AutoNameSpeakersTests.swift`:

```swift
import XCTest
@testable import Meeting

final class AutoNameSpeakersTests: XCTestCase {

    private func suggestion(
        speaker: String, identity: String, name: String,
        score: Double, percent: Int
    ) -> IdentitySuggestion {
        IdentitySuggestion(
            speakerID: SpeakerID(rawValue: speaker),
            identityID: identity,
            identityDisplayName: name,
            score: score,
            confidencePercent: percent
        )
    }

    private func defaultProfile(_ speaker: String, name: String) -> SpeakerProfile {
        SpeakerProfile(id: SpeakerID(rawValue: speaker), displayName: name)
    }

    func test_appliesSuggestionAtOrAboveThreshold() {
        let sugg = suggestion(speaker: "speaker_0", identity: "id-a", name: "Somchai", score: 0.8, percent: 82)
        let profiles = [defaultProfile("speaker_0", name: "Speaker 1")]
        let picked = MeetingsLibrary.autoNameSelections(
            suggestions: [sugg], profiles: profiles, enabled: true, thresholdPercent: 80
        )
        XCTAssertEqual(picked.map(\.id), [sugg.id])
    }

    func test_skipsSuggestionBelowThreshold() {
        let sugg = suggestion(speaker: "speaker_0", identity: "id-a", name: "Somchai", score: 0.7, percent: 71)
        let profiles = [defaultProfile("speaker_0", name: "Speaker 1")]
        let picked = MeetingsLibrary.autoNameSelections(
            suggestions: [sugg], profiles: profiles, enabled: true, thresholdPercent: 80
        )
        XCTAssertTrue(picked.isEmpty)
    }

    func test_skipsSpeakerThatAlreadyHasAnIdentity() {
        let sugg = suggestion(speaker: "speaker_0", identity: "id-a", name: "Somchai", score: 0.9, percent: 95)
        var profile = defaultProfile("speaker_0", name: "Speaker 1")
        profile.identityID = "id-existing"
        let picked = MeetingsLibrary.autoNameSelections(
            suggestions: [sugg], profiles: [profile], enabled: true, thresholdPercent: 80
        )
        XCTAssertTrue(picked.isEmpty)
    }

    func test_skipsSpeakerWithManualCustomName() {
        let sugg = suggestion(speaker: "speaker_0", identity: "id-a", name: "Somchai", score: 0.9, percent: 95)
        let profile = defaultProfile("speaker_0", name: "Nok")  // hand-typed, not a default label
        let picked = MeetingsLibrary.autoNameSelections(
            suggestions: [sugg], profiles: [profile], enabled: true, thresholdPercent: 80
        )
        XCTAssertTrue(picked.isEmpty)
    }

    func test_disabledReturnsEmpty() {
        let sugg = suggestion(speaker: "speaker_0", identity: "id-a", name: "Somchai", score: 0.9, percent: 95)
        let profiles = [defaultProfile("speaker_0", name: "Speaker 1")]
        let picked = MeetingsLibrary.autoNameSelections(
            suggestions: [sugg], profiles: profiles, enabled: false, thresholdPercent: 80
        )
        XCTAssertTrue(picked.isEmpty)
    }

    func test_picksHighestScoringSuggestionPerSpeaker() {
        let low = suggestion(speaker: "speaker_0", identity: "id-a", name: "Somchai", score: 0.81, percent: 81)
        let high = suggestion(speaker: "speaker_0", identity: "id-b", name: "Somsri", score: 0.92, percent: 95)
        let profiles = [defaultProfile("speaker_0", name: "Speaker 1")]
        let picked = MeetingsLibrary.autoNameSelections(
            suggestions: [low, high], profiles: profiles, enabled: true, thresholdPercent: 80
        )
        XCTAssertEqual(picked.map(\.identityID), ["id-b"])
    }

    func test_oldSpeakerProfileJSONDecodesWithoutAutoField() throws {
        // speakers.json written before this feature has no autoNamedConfidence key.
        let json = """
        { "id": { "rawValue": "speaker_0" }, "displayName": "Speaker 1" }
        """.data(using: .utf8)!
        let profile = try JSONDecoder().decode(SpeakerProfile.self, from: json)
        XCTAssertNil(profile.autoNamedConfidence)
        XCTAssertFalse(profile.autoNamed)
    }
}
```

- [ ] **Step 2: Regenerate the project so the new test file is picked up**

Run:
```bash
xcodegen generate
```
Expected: `Created project at .../Meeting.xcodeproj`

- [ ] **Step 3: Run the tests to verify they fail (helper undefined)**

```bash
pkill -9 -f "Meeting.app" 2>/dev/null; \
xcodebuild -project Meeting.xcodeproj -scheme Meeting -configuration Debug \
  -destination 'platform=macOS' \
  -only-testing:MeetingTests/AutoNameSpeakersTests test 2>&1 | tail -20
```
Expected: COMPILE FAILURE — `type 'MeetingsLibrary' has no member 'autoNameSelections'`.

- [ ] **Step 4: Implement the pure helpers**

In `Meeting/Library/MeetingsLibrary.swift`, add these `nonisolated static` methods
(place them just above `applyIdentitySuggestion` at line 373):

```swift
    /// True when a speaker's displayName is still a system default ("speaker_N",
    /// "Speaker N", or "unknown") rather than a user- or auto-assigned name.
    /// Mirrors the unmapped-speaker test in `loadRecord`.
    nonisolated static func isDefaultSpeakerName(_ displayName: String) -> Bool {
        let lower = displayName.lowercased()
        let normalized = lower.replacingOccurrences(of: " ", with: "_")
        return normalized.hasPrefix("speaker_") || lower == "unknown"
    }

    /// Pure selection: which suggestions should be auto-applied. Returns at most
    /// one per speaker (the highest-scoring), keeping only those whose
    /// `confidencePercent` ≥ `thresholdPercent` and whose speaker is still on a
    /// default name with no identity yet. Empty when `enabled` is false.
    nonisolated static func autoNameSelections(
        suggestions: [IdentitySuggestion],
        profiles: [SpeakerProfile],
        enabled: Bool,
        thresholdPercent: Int
    ) -> [IdentitySuggestion] {
        guard enabled else { return [] }
        var bestBySpeaker: [SpeakerID: IdentitySuggestion] = [:]
        for s in suggestions {
            if let existing = bestBySpeaker[s.speakerID], existing.score >= s.score { continue }
            bestBySpeaker[s.speakerID] = s
        }
        return bestBySpeaker.values
            .filter { s in
                guard s.confidencePercent >= thresholdPercent else { return false }
                guard let p = profiles.first(where: { $0.id == s.speakerID }) else { return true }
                return p.identityID == nil && isDefaultSpeakerName(p.displayName)
            }
            .sorted { $0.score > $1.score }
    }
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
pkill -9 -f "Meeting.app" 2>/dev/null; \
xcodebuild -project Meeting.xcodeproj -scheme Meeting -configuration Debug \
  -destination 'platform=macOS' \
  -only-testing:MeetingTests/AutoNameSpeakersTests test 2>&1 | tail -20
```
Expected: `Test Suite 'AutoNameSpeakersTests' passed` — 7 tests, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add Meeting/Library/MeetingsLibrary.swift MeetingTests/AutoNameSpeakersTests.swift Meeting.xcodeproj
git commit -m "Add pure autoNameSelections helper + tests"
```

---

### Task 4: Apply + revert methods on MeetingsLibrary

**Files:**
- Modify: `Meeting/Library/MeetingsLibrary.swift:373-397` (`applyIdentitySuggestion`), and add `autoNameSpeakers` + `revertAutoName` after `rejectIdentitySuggestion` (after line 416)

- [ ] **Step 1: Extend `applyIdentitySuggestion` to optionally tag confidence**

Change the signature and the `updateSpeaker` transform in `applyIdentitySuggestion`
(lines 373, 389-395). Replace:

```swift
    func applyIdentitySuggestion(_ suggestion: IdentitySuggestion, meeting: MeetingRecord.ID) {
```
with:
```swift
    func applyIdentitySuggestion(
        _ suggestion: IdentitySuggestion,
        meeting: MeetingRecord.ID,
        autoConfidence: Int? = nil
    ) {
```

And replace the transform block (lines 389-395):

```swift
        updateSpeaker(meeting: meeting, speakerID: suggestion.speakerID, refresh: false) { profile in
            profile.displayName = identity.displayName
            profile.identityID = identity.id
            if profile.email == nil, let email = identity.emails.first {
                profile.email = email
            }
        }
```
with:
```swift
        updateSpeaker(meeting: meeting, speakerID: suggestion.speakerID, refresh: false) { profile in
            profile.displayName = identity.displayName
            profile.identityID = identity.id
            if profile.email == nil, let email = identity.emails.first {
                profile.email = email
            }
            // Tag (or clear) the auto-named marker. A manual accept passes nil,
            // which clears any prior auto badge on re-confirm.
            profile.autoNamedConfidence = autoConfidence
        }
```

(The existing manual call site at `TranscriptViewerView.swift:701` keeps working —
`autoConfidence` defaults to `nil`.)

- [ ] **Step 2: Add `autoNameSpeakers(folder:)` and `revertAutoName(...)`**

After `rejectIdentitySuggestion` (line 416), add:

```swift
    /// Auto-apply high-confidence identity suggestions for one meeting. Called
    /// once per meeting from the embedding-extraction completion hook, after a
    /// rescan has populated `identitySuggestions`. Each applied name is tagged
    /// with its confidence so the UI can badge and revert it. No-op when the
    /// feature is off or nothing clears the threshold.
    func autoNameSpeakers(folder: URL) {
        let prefs = AppPreferences.shared
        guard prefs.autoNameSpeakersEnabled else { return }
        guard let m = meetings.first(where: { $0.folder == folder }) else { return }
        let thresholdPercent = Int(prefs.autoNameThreshold * 100)
        let selections = Self.autoNameSelections(
            suggestions: m.identitySuggestions,
            profiles: m.speakerProfiles,
            enabled: true,
            thresholdPercent: thresholdPercent
        )
        guard !selections.isEmpty else { return }
        for suggestion in selections {
            applyIdentitySuggestion(suggestion, meeting: m.id,
                                    autoConfidence: suggestion.confidencePercent)
        }
    }

    /// Undo an auto-applied name: reset the speaker back to its default label,
    /// drop the identity link + auto marker, so the suggestion chip reappears.
    /// Does not un-merge the voice centroid that was folded into the identity
    /// (same as renaming a speaker back by hand) — acceptable, and rare.
    func revertAutoName(speakerID: SpeakerID, meeting: MeetingRecord.ID) {
        let defaultName: String
        if let idx = TranscriptMerger.diarizedIndex(speakerID) {
            defaultName = "Speaker \(idx + 1)"
        } else {
            defaultName = speakerID.rawValue
        }
        updateSpeaker(meeting: meeting, speakerID: speakerID) { profile in
            profile.displayName = defaultName
            profile.identityID = nil
            profile.email = nil
            profile.attendeeId = nil
            profile.role = nil
            profile.autoNamedConfidence = nil
        }
    }
```

- [ ] **Step 3: Build to verify**

```bash
xcodebuild -project Meeting.xcodeproj -scheme Meeting -configuration Debug \
  -destination 'platform=macOS' CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add Meeting/Library/MeetingsLibrary.swift
git commit -m "MeetingsLibrary: autoNameSpeakers + revertAutoName apply paths"
```

---

### Task 5: Trigger — embedding-completion callback + AppState wiring

**Files:**
- Modify: `Meeting/Identity/EmbeddingExtractionQueue.swift:16-25,50-70`
- Modify: `Meeting/App/AppState.swift:178-184`

- [ ] **Step 1: Add the per-meeting completion callback to the queue**

In `EmbeddingExtractionQueue.swift`, after the `onActiveChanged` property (line 16), add:

```swift
    /// Notified with a meeting folder right after its `embeddings.json` is
    /// successfully written — the first moment identity suggestions become
    /// computable. Drives the auto-name pass.
    var onMeetingEmbedded: (@Sendable (URL) -> Void)?
```

After `setOnActiveChanged(_:)` (ends line 25), add:

```swift
    func setOnMeetingEmbedded(_ callback: @escaping @Sendable (URL) -> Void) {
        self.onMeetingEmbedded = callback
    }
```

Then in `process(folder:)`, fire it only on the success path. Replace (lines 55-69):

```swift
        do {
            try await runExtraction(folder: folder)
        } catch {
            NSLog("[Meeting/Identity] extraction failed for %@: %@",
                  folder.lastPathComponent, String(describing: error))
            // Persist failure flag so we don't loop on the next scan
            let file = MeetingEmbeddingsFile(
                schemaVersion: 1,
                embedderModel: SpeakerEmbedder.modelTag,
                embeddings: [],
                rejectedIdentities: [],
                embeddingFailed: true
            )
            try? file.write(to: folder)
        }
```
with:
```swift
        do {
            try await runExtraction(folder: folder)
            onMeetingEmbedded?(folder)
        } catch {
            NSLog("[Meeting/Identity] extraction failed for %@: %@",
                  folder.lastPathComponent, String(describing: error))
            // Persist failure flag so we don't loop on the next scan
            let file = MeetingEmbeddingsFile(
                schemaVersion: 1,
                embedderModel: SpeakerEmbedder.modelTag,
                embeddings: [],
                rejectedIdentities: [],
                embeddingFailed: true
            )
            try? file.write(to: folder)
        }
```

Note: `runExtraction` returns early (skips) only at the top of `process` when
`embeddings.json` already exists, so the callback fires once per meeting — exactly
when embeddings are first written. Re-transcribe with an existing cache won't re-fire.

- [ ] **Step 2: Wire the callback in AppState**

In `AppState.swift`, right after the existing `setOnActiveChanged` wiring block
(ends line 184), add a parallel block:

```swift
        Task { [unowned self] in
            await embeddingQueue.setOnMeetingEmbedded { folder in
                Task { @MainActor [unowned self] in
                    // Rescan so the just-written embeddings produce fresh
                    // identitySuggestions on the record, then auto-apply the
                    // high-confidence ones.
                    self.library.rescan()
                    self.library.autoNameSpeakers(folder: folder)
                }
            }
        }
```

- [ ] **Step 3: Build to verify**

```bash
xcodebuild -project Meeting.xcodeproj -scheme Meeting -configuration Debug \
  -destination 'platform=macOS' CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add Meeting/Identity/EmbeddingExtractionQueue.swift Meeting/App/AppState.swift
git commit -m "Trigger auto-name pass when embeddings finish extracting"
```

---

### Task 6: Settings UI — toggle + threshold slider

**Files:**
- Modify: `Meeting/App/SettingsView.swift:408-409` (insert before the "Stored identities" divider)

- [ ] **Step 1: Insert the auto-name controls into `IdentityMatchingSection`**

In `SettingsView.swift`, inside `IdentityMatchingSection.body`, after the suggestion
threshold `HStack` closes (line 408) and **before** `Divider().opacity(0.4)` at line 409,
insert:

```swift
            Divider().opacity(0.4)
            ToggleRow(
                title: "Auto-name when confident",
                description: "When a speaker's voice matches a known person above the threshold below, fill in their name automatically. Auto-named speakers show a ✨ badge and can be reverted.",
                isOn: Binding(
                    get: { prefs.autoNameSpeakersEnabled },
                    set: { prefs.autoNameSpeakersEnabled = $0 }
                )
            )
            .disabled(!prefs.identitySuggestionsEnabled)
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Auto-name threshold")
                        .font(.system(size: 13, weight: .medium))
                    Text("Only auto-name at or above this confidence. Higher is safer.")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.textDim)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(Int(prefs.autoNameThreshold * 100))%")
                        .font(.system(size: 12, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Color.textDim)
                    Slider(
                        value: Binding(
                            get: { prefs.autoNameThreshold },
                            set: { prefs.autoNameThreshold = $0 }
                        ),
                        in: 0.60...0.95,
                        step: 0.05
                    )
                    .frame(width: 160)
                }
                .disabled(!prefs.identitySuggestionsEnabled || !prefs.autoNameSpeakersEnabled)
            }
```

(This leaves the original `Divider().opacity(0.4)` at line 409 in place, so the
"Stored identities" row keeps its separator.)

- [ ] **Step 2: Build to verify**

```bash
xcodebuild -project Meeting.xcodeproj -scheme Meeting -configuration Debug \
  -destination 'platform=macOS' CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Meeting/App/SettingsView.swift
git commit -m "Settings: auto-name toggle + threshold slider"
```

---

### Task 7: Transcript Viewer — auto badge + revert

**Files:**
- Modify: `Meeting/Transcribe/TranscriptViewerView.swift:695-705` (speakers panel ForEach)

- [ ] **Step 1: Render the badge + revert under auto-named speakers**

In `TranscriptViewerView.swift`, the speakers panel currently shows the suggestion chip
for un-named speakers (lines 695-705). For an auto-named speaker there is no suggestion
(its name is already set), so add a sibling branch. Replace lines 695-705:

```swift
                    // Suggestion chip — surfaces under speakers that the
                    // matcher believes match a previously-named voice.
                    if let suggestion = meeting.identitySuggestions.first(where: { $0.speakerID == speaker.id }) {
                        IdentitySuggestionChip(
                            suggestion: suggestion,
                            allSuggestions: meeting.identitySuggestions.filter { $0.speakerID == speaker.id },
                            onConfirm: { s in library.applyIdentitySuggestion(s, meeting: meeting.id) },
                            onReject: { s in library.rejectIdentitySuggestion(s, meeting: meeting.id) }
                        )
                        .padding(.leading, 32)
                    }
```
with:
```swift
                    // Suggestion chip — surfaces under speakers that the
                    // matcher believes match a previously-named voice.
                    if let suggestion = meeting.identitySuggestions.first(where: { $0.speakerID == speaker.id }) {
                        IdentitySuggestionChip(
                            suggestion: suggestion,
                            allSuggestions: meeting.identitySuggestions.filter { $0.speakerID == speaker.id },
                            onConfirm: { s in library.applyIdentitySuggestion(s, meeting: meeting.id) },
                            onReject: { s in library.rejectIdentitySuggestion(s, meeting: meeting.id) }
                        )
                        .padding(.leading, 32)
                    } else if let profile = meeting.speakerProfiles.first(where: { $0.id == speaker.id }),
                              let confidence = profile.autoNamedConfidence {
                        AutoNamedBadge(
                            confidence: confidence,
                            onRevert: { library.revertAutoName(speakerID: speaker.id, meeting: meeting.id) }
                        )
                        .padding(.leading, 32)
                    }
```

- [ ] **Step 2: Add the `AutoNamedBadge` view**

Add this small view next to `IdentitySuggestionChip` (after its definition ends — find
the closing brace of `private struct IdentitySuggestionChip` near line 2018):

```swift
/// Shown under a speaker whose name was filled in automatically by the
/// auto-name pass. Communicates "this was a guess, here's how confident, undo it".
private struct AutoNamedBadge: View {
    let confidence: Int
    let onRevert: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text("✨ auto · \(confidence)%")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.textDim)
            Button(action: onRevert) {
                Text("Revert")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.brandAccent)
        }
    }
}
```

- [ ] **Step 3: Build to verify**

```bash
xcodebuild -project Meeting.xcodeproj -scheme Meeting -configuration Debug \
  -destination 'platform=macOS' CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add Meeting/Transcribe/TranscriptViewerView.swift
git commit -m "Transcript Viewer: auto-named badge + revert"
```

---

### Task 8: Full test suite + final verification

- [ ] **Step 1: Regenerate and run the full suite**

```bash
pkill -9 -f "Meeting.app" 2>/dev/null; xcodegen generate; \
xcodebuild -project Meeting.xcodeproj -scheme Meeting -configuration Debug \
  -destination 'platform=macOS' test 2>&1 | tail -25
```
Expected: `** TEST SUCCEEDED **`, all tests passing including `AutoNameSpeakersTests`.

- [ ] **Step 2: Manual smoke check (build + run, signed)**

```bash
xcodebuild -project Meeting.xcodeproj -scheme Meeting -configuration Debug \
  -destination 'platform=macOS' build 2>&1 | tail -5
```
Then: open Settings → Identity matching, confirm the "Auto-name when confident" toggle
(ON) and "Auto-name threshold" slider (80%) appear and the slider disables when the
toggle or "Suggest speakers" is off.

- [ ] **Step 3: Commit any regen artifacts**

```bash
git add -A
git commit -m "Auto-name speakers: full suite green" || echo "nothing to commit"
```

---

## Self-Review notes

- **Spec coverage:** field (Task 1), prefs (Task 2), Settings UI (Task 6), auto-apply pass
  + threshold compare in percent space (Tasks 3–4), trigger right after transcription
  (Task 5), badge + revert (Task 7), tests (Task 3, Task 8). Safety rules (never overwrite
  manual names / already-identified speakers; off = no-op) are enforced in
  `autoNameSelections` and covered by tests.
- **Threshold semantics:** stored as a 0–1 Double, compared as `confidencePercent >= Int(threshold*100)`, matching the percent the user sees on the chip. Consistent across Task 4 (apply) and Task 6 (display).
- **Naming consistency:** `autoNamedConfidence` (stored), `autoNamed` (computed),
  `autoNameSpeakersEnabled`, `autoNameThreshold`, `autoNameSelections`, `autoNameSpeakers`,
  `revertAutoName`, `onMeetingEmbedded`, `AutoNamedBadge` — used identically everywhere.
- **One-shot guarantee:** the trigger fires from `EmbeddingExtractionQueue` only on first
  successful extraction per meeting (cache-skip guard at top of `process`), so meetings are
  not re-written on later scans — matching the chosen "right after transcription" behavior.
- **Backward compatibility:** the single new persisted field is optional, so existing
  `speakers.json` files decode unchanged (covered by `test_oldSpeakerProfileJSONDecodesWithoutAutoField`).
```
