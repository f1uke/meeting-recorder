# Cross-meeting speaker identity V1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Auto-suggest mapping `speaker_N` ↔ คนจริง ใน Transcript Viewer โดยใช้ pyannote v3 acoustic embedding (192-dim) + calendar email / Meet name / recency priors

**Architecture:** Layer ใหม่ `Meeting/Identity/` มี `SpeakerEmbedder` (actor, wraps argmax pyannote v3 Core ML files), `IdentityStore` (`@MainActor` ObservableObject เก็บ identities.json), `IdentityMatcher` (pure scoring), และ `EmbeddingExtractionQueue` (actor serial). MeetingsLibrary หลังโหลดแต่ละ meeting จะรัน matcher → `MeetingRecord.identitySuggestions`. Transcript Viewer แสดง chip ใต้ speaker_N + banner ด้านบน

**Tech Stack:** Swift 6 strict concurrency, SwiftUI, Core ML (pyannote-v3-w8a16 ที่ SpeakerKit download มาแล้ว), Accelerate (vDSP สำหรับ dot product / L2 norm), XCTest

**Spec:** `docs/superpowers/specs/2026-05-15-cross-meeting-speaker-identity-design.md`

---

## File Structure

### New files

| Path | Responsibility |
|---|---|
| `Meeting/Identity/Identity.swift` | `Identity` struct + `IdentityStoreFile` Codable shape |
| `Meeting/Identity/IdentityStore.swift` | `@MainActor` ObservableObject — load/save/append/update/delete + corrupt-file recovery |
| `Meeting/Identity/MeetingEmbeddingsFile.swift` | `SpeakerEmbedding`, `Rejection`, `MeetingEmbeddingsFile` Codable + atomic write |
| `Meeting/Identity/SpeakerEmbedderHelpers.swift` | Pure functions: concatenate / chunk / L2 normalize / cosine — no Core ML, easy to test |
| `Meeting/Identity/SpeakerEmbedder.swift` | `actor` wrapping pyannote v3 Core ML inference — `embed(audioSegments:) -> [Float]?` |
| `Meeting/Identity/IdentityMatcher.swift` | Pure scoring + greedy mutual exclusion → `[IdentitySuggestion]` |
| `Meeting/Identity/IdentitySuggestion.swift` | DTO returned by matcher; carries speakerID, identityID, score, confidence |
| `Meeting/Identity/EmbeddingExtractionQueue.swift` | `actor` serial queue — embed pending meetings one at a time |

### Modified files

| Path | Change |
|---|---|
| `Meeting/Library/SpeakerMapFile.swift` | `SpeakerProfile` เพิ่ม `identityID: String?` (optional, backward-compat) |
| `Meeting/Library/MeetingRecord.swift` | เพิ่ม `identitySuggestions: [IdentitySuggestion]` (in-memory, non-Codable) |
| `Meeting/Library/MeetingsLibrary.swift` | `loadRecord()` รัน matcher + เพิ่ม `applyIdentitySuggestion` / `rejectIdentitySuggestion` |
| `Meeting/Transcribe/TranscriptionSession.swift` | หลัง diarize เสร็จ → enqueue meeting ลง `EmbeddingExtractionQueue` |
| `Meeting/Transcribe/TranscriptViewerView.swift` | Suggestion chip ใต้ speaker + top banner |
| `Meeting/App/AppState.swift` | ถือ `IdentityStore` + `EmbeddingExtractionQueue` + inject ผ่าน `AppEnvironment` |
| `Meeting/App/AppEnvironment.swift` | EnvironmentKey เพิ่ม `identityStore` + `embeddingQueue` |
| `Meeting/App/AppPreferences.swift` | เพิ่ม `identitySuggestionsEnabled`, `identitySuggestionThreshold` |
| `Meeting/App/SettingsScene.swift` (หรือเทียบเท่าที่มี) | Identity Matching section |
| `Meeting/App/MenuBarLabel.swift` | เพิ่ม `embedding` intermediate state |

### Test files

| Path | Covers |
|---|---|
| `MeetingTests/IdentityFileTests.swift` | `IdentityStoreFile` roundtrip, schemaVersion check, corrupt fallback |
| `MeetingTests/IdentityStoreTests.swift` | append / update centroid (running mean) / delete / load fresh |
| `MeetingTests/MeetingEmbeddingsFileTests.swift` | Roundtrip + rejection append |
| `MeetingTests/SpeakerProfileBackwardCompatTests.swift` | Decode old `speakers.json` (ไม่มี `identityID`) ได้ |
| `MeetingTests/SpeakerEmbedderHelpersTests.swift` | concat / chunk / L2 normalize / cosine |
| `MeetingTests/SpeakerEmbedderIntegrationTests.swift` | Load Core ML จริง → embed test audio → verify shape 192 |
| `MeetingTests/IdentityMatcherTests.swift` | Per-term priors + composite score + threshold + mutual exclusion |
| `MeetingTests/IdentitySuggestionConfidenceTests.swift` | Score → percent mapping edge cases |
| `MeetingTests/fixtures/two-speaker-5s.wav` | 16 kHz mono, 5s test audio (binary asset committed) |

### XcodeGen note

`project.yml` มี `sources: - path: Meeting` แบบ recursive — โฟลเดอร์ `Meeting/Identity/` ใหม่จะถูก scan อัตโนมัติ **แต่ต้องรัน `xcodegen generate` หลังจากเพิ่มไฟล์แรกใน folder ใหม่** เพื่อให้ Xcode รู้จัก

---

## Task 1: Identity types + IdentityStoreFile Codable

**Files:**
- Create: `Meeting/Identity/Identity.swift`
- Create: `MeetingTests/IdentityFileTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// MeetingTests/IdentityFileTests.swift
import XCTest
@testable import Meeting

final class IdentityFileTests: XCTestCase {
    func test_roundTrip_preservesAllFields() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let identity = Identity(
            id: "abc-123",
            displayName: "Sun Sarin",
            emails: ["sun@example.com"],
            centroid: [Float](repeating: 0.1, count: 192),
            sampleSeconds: 142.3,
            seenIn: ["2026-05-15_10-00-00", "2026-05-08_10-00-00"],
            meetingCount: 2,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_001_000)
        )
        let file = IdentityStoreFile(
            schemaVersion: 1,
            embedderModel: "pyannote-v3-w8a16",
            identities: [identity]
        )

        let url = folder.appendingPathComponent("identities.json")
        try file.write(to: url)
        let restored = try IdentityStoreFile.read(from: url)

        XCTAssertEqual(restored.schemaVersion, 1)
        XCTAssertEqual(restored.embedderModel, "pyannote-v3-w8a16")
        XCTAssertEqual(restored.identities.count, 1)
        XCTAssertEqual(restored.identities[0], identity)
    }

    func test_read_missingFile_throws() {
        let url = URL(fileURLWithPath: "/tmp/nonexistent-\(UUID().uuidString).json")
        XCTAssertThrowsError(try IdentityStoreFile.read(from: url))
    }
}
```

- [ ] **Step 2: Run test to verify it fails (compile error: Identity not found)**

```
xcodebuild -project Meeting.xcodeproj -scheme Meeting -destination 'platform=macOS' \
  -only-testing:MeetingTests/IdentityFileTests test
```
Expected: BUILD FAILED — `Identity` undefined

- [ ] **Step 3: Create `Meeting/Identity/Identity.swift`**

```swift
import Foundation

/// One person across all meetings. Centroid is the running mean of their
/// pyannote v3 embeddings, weighted by `sampleSeconds`.
struct Identity: Codable, Hashable, Sendable, Identifiable {
    let id: String
    var displayName: String
    var emails: [String]
    var centroid: [Float]
    var sampleSeconds: Double
    var seenIn: [String]
    var meetingCount: Int
    var createdAt: Date
    var updatedAt: Date
}

/// On-disk shape of `~/Library/Application Support/dev.fluke.meeting/identities.json`.
struct IdentityStoreFile: Codable, Sendable {
    var schemaVersion: Int
    var embedderModel: String
    var identities: [Identity]

    init(schemaVersion: Int = 1, embedderModel: String, identities: [Identity] = []) {
        self.schemaVersion = schemaVersion
        self.embedderModel = embedderModel
        self.identities = identities
    }

    static func read(from url: URL) throws -> IdentityStoreFile {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(IdentityStoreFile.self, from: data)
    }

    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: url, options: [.atomic])
    }
}
```

- [ ] **Step 4: Update read/write to use iso8601 dates consistently**

ใน `read()` เพิ่ม `decoder.dateDecodingStrategy = .iso8601`:

```swift
    static func read(from url: URL) throws -> IdentityStoreFile {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(IdentityStoreFile.self, from: data)
    }
```

- [ ] **Step 5: Run xcodegen + tests**

```
xcodegen generate && \
xcodebuild -project Meeting.xcodeproj -scheme Meeting -destination 'platform=macOS' \
  -only-testing:MeetingTests/IdentityFileTests test
```
Expected: PASS (2 tests)

- [ ] **Step 6: Commit**

```bash
git add Meeting/Identity/Identity.swift MeetingTests/IdentityFileTests.swift Meeting.xcodeproj
git commit -m "add Identity + IdentityStoreFile types"
```

---

## Task 2: IdentityStore — load/save/append/update/delete

**Files:**
- Create: `Meeting/Identity/IdentityStore.swift`
- Create: `MeetingTests/IdentityStoreTests.swift`

- [ ] **Step 1: Write tests for empty store + append + update centroid (running mean) + delete + corrupt fallback**

```swift
// MeetingTests/IdentityStoreTests.swift
import XCTest
@testable import Meeting

@MainActor
final class IdentityStoreTests: XCTestCase {
    func test_emptyStore_loadsClean() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = IdentityStore(fileURL: folder.appendingPathComponent("identities.json"))
        XCTAssertTrue(store.identities.isEmpty)
        XCTAssertEqual(store.embedderModel, SpeakerEmbedder.modelTag)
    }

    func test_create_persistsAndReloads() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("identities.json")

        let store = IdentityStore(fileURL: url)
        let id = store.create(
            displayName: "Sun Sarin",
            email: nil,
            centroid: [Float](repeating: 0.1, count: 192),
            sampleSeconds: 60,
            meetingFolder: "2026-05-15_10-00-00"
        )

        let store2 = IdentityStore(fileURL: url)
        XCTAssertEqual(store2.identities.count, 1)
        XCTAssertEqual(store2.identities[0].id, id)
        XCTAssertEqual(store2.identities[0].displayName, "Sun Sarin")
        XCTAssertEqual(store2.identities[0].meetingCount, 1)
    }

    func test_updateCentroid_runningMeanWeightsBySampleSeconds() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = IdentityStore(fileURL: folder.appendingPathComponent("identities.json"))

        let c1 = unitVector(seed: 1, dim: 192)
        let c2 = unitVector(seed: 2, dim: 192)
        let id = store.create(
            displayName: "X",
            email: nil,
            centroid: c1,
            sampleSeconds: 30,
            meetingFolder: "A"
        )
        store.updateCentroid(id: id, newCentroid: c2, newSampleSeconds: 90, meetingFolder: "B")

        let updated = store.identities[0]
        XCTAssertEqual(updated.sampleSeconds, 120, accuracy: 0.01)
        XCTAssertEqual(updated.meetingCount, 2)
        XCTAssertEqual(updated.seenIn, ["B", "A"])
        // running mean: (30 * c1 + 90 * c2) / 120 then L2-normalize
        // verify result is unit length
        let norm = sqrt(updated.centroid.reduce(into: Float(0)) { $0 += $1 * $1 })
        XCTAssertEqual(norm, 1.0, accuracy: 0.001)
    }

    func test_delete_removesIdentity() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = IdentityStore(fileURL: folder.appendingPathComponent("identities.json"))

        let id = store.create(displayName: "X", email: nil, centroid: unitVector(seed: 1, dim: 192),
                              sampleSeconds: 10, meetingFolder: "A")
        store.delete(id: id)
        XCTAssertTrue(store.identities.isEmpty)
    }

    func test_corruptFile_backsUpAndStartsFresh() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("identities.json")
        try Data("not json".utf8).write(to: url)

        let store = IdentityStore(fileURL: url)
        XCTAssertTrue(store.identities.isEmpty)
        let backups = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasPrefix("identities.json.corrupt-") }
        XCTAssertEqual(backups.count, 1)
    }
}

// Test helper — deterministic unit-norm vector for centroid math tests
private func unitVector(seed: Int, dim: Int) -> [Float] {
    var v = (0..<dim).map { Float(sin(Double(seed * 17 + $0))) }
    let norm = sqrt(v.reduce(into: Float(0)) { $0 += $1 * $1 })
    for i in 0..<v.count { v[i] /= norm }
    return v
}
```

- [ ] **Step 2: Run test to verify it fails**

```
xcodebuild -project Meeting.xcodeproj -scheme Meeting -destination 'platform=macOS' \
  -only-testing:MeetingTests/IdentityStoreTests test
```
Expected: FAIL (IdentityStore undefined)

- [ ] **Step 3: Create `Meeting/Identity/IdentityStore.swift`**

```swift
import Foundation
import Combine
import Accelerate

@MainActor
final class IdentityStore: ObservableObject {
    @Published private(set) var identities: [Identity] = []
    let embedderModel: String
    private let fileURL: URL
    private let seenInCap = 50

    init(fileURL: URL, embedderModel: String = SpeakerEmbedder.modelTag) {
        self.fileURL = fileURL
        self.embedderModel = embedderModel
        load()
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else {
            return
        }
        do {
            let file = try IdentityStoreFile.read(from: fileURL)
            if file.embedderModel == embedderModel {
                identities = file.identities
            } else {
                NSLog("[Meeting/Identity] embedderModel mismatch (stored=%@ current=%@) — keeping in-memory empty store",
                      file.embedderModel, embedderModel)
            }
        } catch {
            let backup = fileURL.deletingLastPathComponent()
                .appendingPathComponent("identities.json.corrupt-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            NSLog("[Meeting/Identity] identities.json parse failed (backed up to %@): %@",
                  backup.lastPathComponent, String(describing: error))
        }
    }

    private func save() {
        let file = IdentityStoreFile(
            schemaVersion: 1,
            embedderModel: embedderModel,
            identities: identities
        )
        do {
            try file.write(to: fileURL)
        } catch {
            NSLog("[Meeting/Identity] identities.json write failed: %@", String(describing: error))
        }
    }

    @discardableResult
    func create(
        displayName: String,
        email: String?,
        centroid: [Float],
        sampleSeconds: Double,
        meetingFolder: String
    ) -> String {
        let now = Date()
        let id = UUID().uuidString
        let identity = Identity(
            id: id,
            displayName: displayName,
            emails: email.map { [$0.lowercased()] } ?? [],
            centroid: l2Normalize(centroid),
            sampleSeconds: sampleSeconds,
            seenIn: [meetingFolder],
            meetingCount: 1,
            createdAt: now,
            updatedAt: now
        )
        identities.append(identity)
        save()
        return id
    }

    func updateCentroid(
        id: String,
        newCentroid: [Float],
        newSampleSeconds: Double,
        meetingFolder: String
    ) {
        guard let idx = identities.firstIndex(where: { $0.id == id }) else { return }
        var iden = identities[idx]
        let wOld = iden.sampleSeconds
        let wNew = newSampleSeconds
        let total = wOld + wNew
        var blended = [Float](repeating: 0, count: iden.centroid.count)
        for i in 0..<blended.count {
            blended[i] = Float((Double(iden.centroid[i]) * wOld
                              + Double(newCentroid[i]) * wNew) / total)
        }
        iden.centroid = l2Normalize(blended)
        iden.sampleSeconds = total
        var seen = iden.seenIn.filter { $0 != meetingFolder }
        seen.insert(meetingFolder, at: 0)
        iden.seenIn = Array(seen.prefix(seenInCap))
        iden.meetingCount += 1
        iden.updatedAt = Date()
        identities[idx] = iden
        save()
    }

    func updateDisplayName(id: String, newName: String) {
        guard let idx = identities.firstIndex(where: { $0.id == id }) else { return }
        identities[idx].displayName = newName
        identities[idx].updatedAt = Date()
        save()
    }

    func addEmail(id: String, email: String) {
        let lc = email.lowercased()
        guard let idx = identities.firstIndex(where: { $0.id == id }),
              !identities[idx].emails.contains(lc) else { return }
        identities[idx].emails.append(lc)
        identities[idx].updatedAt = Date()
        save()
    }

    func delete(id: String) {
        identities.removeAll { $0.id == id }
        save()
    }

    func reset() {
        identities = []
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func l2Normalize(_ v: [Float]) -> [Float] {
        var sumSq: Float = 0
        vDSP_svesq(v, 1, &sumSq, vDSP_Length(v.count))
        let norm = sqrt(sumSq)
        guard norm > 0 else { return v }
        var divisor = norm
        var out = [Float](repeating: 0, count: v.count)
        vDSP_vsdiv(v, 1, &divisor, &out, 1, vDSP_Length(v.count))
        return out
    }
}
```

- [ ] **Step 4: Run tests**

```
xcodegen generate && \
xcodebuild -project Meeting.xcodeproj -scheme Meeting -destination 'platform=macOS' \
  -only-testing:MeetingTests/IdentityStoreTests test
```
Expected: PASS — but `SpeakerEmbedder.modelTag` is undefined; temporary fix below

- [ ] **Step 5: Add temporary placeholder for `SpeakerEmbedder.modelTag`**

จะถูก replace ใน Task 6 — ตอนนี้แค่ให้ compile ผ่าน เพิ่มไฟล์ stub:

```swift
// Meeting/Identity/SpeakerEmbedder.swift (stub — Task 6 จะ replace)
import Foundation
actor SpeakerEmbedder {
    static let modelTag = "pyannote-v3-w8a16"
}
```

- [ ] **Step 6: Re-run xcodegen + tests**

Expected: PASS (5 tests)

- [ ] **Step 7: Commit**

```bash
git add Meeting/Identity/IdentityStore.swift Meeting/Identity/SpeakerEmbedder.swift \
        MeetingTests/IdentityStoreTests.swift Meeting.xcodeproj
git commit -m "add IdentityStore with running-mean centroid update + corrupt-file recovery"
```

---

## Task 3: MeetingEmbeddingsFile + Rejection types

**Files:**
- Create: `Meeting/Identity/MeetingEmbeddingsFile.swift`
- Create: `MeetingTests/MeetingEmbeddingsFileTests.swift`

- [ ] **Step 1: Write tests**

```swift
// MeetingTests/MeetingEmbeddingsFileTests.swift
import XCTest
@testable import Meeting

final class MeetingEmbeddingsFileTests: XCTestCase {
    func test_roundTrip() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let file = MeetingEmbeddingsFile(
            schemaVersion: 1,
            embedderModel: "pyannote-v3-w8a16",
            embeddings: [
                SpeakerEmbedding(
                    speakerID: SpeakerID.diarized(0),
                    centroid: [Float](repeating: 0.1, count: 192),
                    sampleSeconds: 60
                )
            ],
            rejectedIdentities: [
                Rejection(speakerID: SpeakerID.diarized(0), identityID: "abc")
            ],
            embeddingFailed: false
        )
        try file.write(to: folder)
        let restored = try MeetingEmbeddingsFile.read(from: folder)
        XCTAssertEqual(restored, file)
    }

    func test_appendRejection_doesNotDuplicate() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var file = MeetingEmbeddingsFile(
            schemaVersion: 1,
            embedderModel: "pyannote-v3-w8a16",
            embeddings: [],
            rejectedIdentities: [],
            embeddingFailed: false
        )
        let rej = Rejection(speakerID: SpeakerID.diarized(0), identityID: "abc")
        file.appendRejection(rej)
        file.appendRejection(rej)  // duplicate
        XCTAssertEqual(file.rejectedIdentities.count, 1)
    }
}
```

- [ ] **Step 2: Run test to verify it fails (types undefined)**

Expected: BUILD FAILED

- [ ] **Step 3: Create `Meeting/Identity/MeetingEmbeddingsFile.swift`**

```swift
import Foundation

struct SpeakerEmbedding: Codable, Hashable, Sendable {
    let speakerID: SpeakerID
    let centroid: [Float]
    let sampleSeconds: Double
}

struct Rejection: Codable, Hashable, Sendable {
    let speakerID: SpeakerID
    let identityID: String
}

struct MeetingEmbeddingsFile: Codable, Hashable, Sendable {
    static let filename = "embeddings.json"

    var schemaVersion: Int
    var embedderModel: String
    var embeddings: [SpeakerEmbedding]
    var rejectedIdentities: [Rejection]
    var embeddingFailed: Bool

    static func read(from folder: URL) throws -> MeetingEmbeddingsFile {
        let url = folder.appendingPathComponent(filename)
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(MeetingEmbeddingsFile.self, from: data)
    }

    func write(to folder: URL) throws {
        let url = folder.appendingPathComponent(Self.filename)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: [.atomic])
    }

    mutating func appendRejection(_ r: Rejection) {
        guard !rejectedIdentities.contains(r) else { return }
        rejectedIdentities.append(r)
    }
}
```

- [ ] **Step 4: Run tests**

```
xcodegen generate && \
xcodebuild -project Meeting.xcodeproj -scheme Meeting -destination 'platform=macOS' \
  -only-testing:MeetingTests/MeetingEmbeddingsFileTests test
```
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Meeting/Identity/MeetingEmbeddingsFile.swift \
        MeetingTests/MeetingEmbeddingsFileTests.swift Meeting.xcodeproj
git commit -m "add MeetingEmbeddingsFile per-meeting cache"
```

---

## Task 4: SpeakerProfile.identityID — additive schema change

**Files:**
- Modify: `Meeting/Library/SpeakerMapFile.swift`
- Create: `MeetingTests/SpeakerProfileBackwardCompatTests.swift`

- [ ] **Step 1: Write backward-compat test (decode old shape without `identityID`)**

```swift
// MeetingTests/SpeakerProfileBackwardCompatTests.swift
import XCTest
@testable import Meeting

final class SpeakerProfileBackwardCompatTests: XCTestCase {
    func test_decode_oldSpeakerProfileWithoutIdentityID() throws {
        let json = """
        {
          "id": "speaker_0",
          "displayName": "Sun Sarin",
          "attendeeId": null,
          "email": null,
          "role": null
        }
        """
        let data = Data(json.utf8)
        let profile = try JSONDecoder().decode(SpeakerProfile.self, from: data)
        XCTAssertEqual(profile.displayName, "Sun Sarin")
        XCTAssertNil(profile.identityID)
    }

    func test_encodeDecode_newSpeakerProfileWithIdentityID() throws {
        let profile = SpeakerProfile(
            id: SpeakerID.diarized(0),
            displayName: "X",
            identityID: "uuid-123"
        )
        let data = try JSONEncoder().encode(profile)
        let restored = try JSONDecoder().decode(SpeakerProfile.self, from: data)
        XCTAssertEqual(restored.identityID, "uuid-123")
    }
}
```

- [ ] **Step 2: Run test → expect compile fail (init missing identityID param)**

Expected: BUILD FAILED

- [ ] **Step 3: Modify `Meeting/Library/SpeakerMapFile.swift` — add field + init param**

ใน `struct SpeakerProfile`, เพิ่ม `var identityID: String?` หลัง `role`, และเพิ่ม init param:

```swift
struct SpeakerProfile: Codable, Hashable, Sendable {
    let id: SpeakerID
    var displayName: String
    var attendeeId: String?
    var email: String?
    var role: String?
    var identityID: String?   // NEW

    init(
        id: SpeakerID,
        displayName: String,
        attendeeId: String? = nil,
        email: String? = nil,
        role: String? = nil,
        identityID: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.attendeeId = attendeeId
        self.email = email
        self.role = role
        self.identityID = identityID
    }

    var asSpeaker: Speaker {
        Speaker(id: id, displayName: displayName)
    }
}
```

- [ ] **Step 4: Run all SpeakerProfile-related tests**

```
xcodebuild -project Meeting.xcodeproj -scheme Meeting -destination 'platform=macOS' \
  -only-testing:MeetingTests/SpeakerProfileBackwardCompatTests test
```
Expected: PASS (2 tests). ตรวจว่า tests อื่นที่ใช้ `SpeakerProfile(...)` ยังคอมไพล์ผ่าน (init params backward-compat — defaults ทั้งหมด)

- [ ] **Step 5: Run full test suite to catch breakage**

```
xcodebuild -project Meeting.xcodeproj -scheme Meeting -destination 'platform=macOS' test
```
Expected: ทั้งหมด PASS

- [ ] **Step 6: Commit**

```bash
git add Meeting/Library/SpeakerMapFile.swift \
        MeetingTests/SpeakerProfileBackwardCompatTests.swift
git commit -m "SpeakerProfile.identityID — optional, backward-compatible"
```

---

## Task 5: SpeakerEmbedder pure helpers (concat / chunk / L2 / cosine)

**Files:**
- Create: `Meeting/Identity/SpeakerEmbedderHelpers.swift`
- Create: `MeetingTests/SpeakerEmbedderHelpersTests.swift`

- [ ] **Step 1: Write helper tests**

```swift
// MeetingTests/SpeakerEmbedderHelpersTests.swift
import XCTest
@testable import Meeting

final class SpeakerEmbedderHelpersTests: XCTestCase {
    func test_concatenate_joinsSegments() {
        let segs: [[Float]] = [[1, 2, 3], [4, 5], [6]]
        XCTAssertEqual(SpeakerEmbedderHelpers.concatenate(segs), [1, 2, 3, 4, 5, 6])
    }

    func test_chunk_5sWindow_05sOverlap() {
        // 5s @ 16kHz = 80_000 samples; overlap 0.5s = 8_000 samples → hop 72_000
        // For an audio of 160_000 samples (10s), expect chunks at offsets [0, 72_000]
        // (next would be 144_000, which leaves only 16_000 of 80_000 needed — dropped as < 50% full)
        let audio = [Float](repeating: 1.0, count: 160_000)
        let chunks = SpeakerEmbedderHelpers.chunk(audio, chunkSamples: 80_000, hopSamples: 72_000)
        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks[0].count, 80_000)
        XCTAssertEqual(chunks[1].count, 80_000)
    }

    func test_chunk_dropsShortTail() {
        // 80_000 samples exactly = 1 full chunk, no tail
        let audio = [Float](repeating: 1.0, count: 80_000)
        XCTAssertEqual(SpeakerEmbedderHelpers.chunk(audio, chunkSamples: 80_000, hopSamples: 72_000).count, 1)

        // 79_999 — short by 1 → no chunks
        let short = [Float](repeating: 1.0, count: 79_999)
        XCTAssertEqual(SpeakerEmbedderHelpers.chunk(short, chunkSamples: 80_000, hopSamples: 72_000).count, 0)
    }

    func test_l2Normalize_makesUnitVector() {
        let v: [Float] = [3, 4]  // norm = 5
        let u = SpeakerEmbedderHelpers.l2Normalize(v)
        XCTAssertEqual(u[0], 0.6, accuracy: 0.0001)
        XCTAssertEqual(u[1], 0.8, accuracy: 0.0001)
    }

    func test_l2Normalize_zeroVector_returnsZero() {
        let v: [Float] = [0, 0, 0]
        XCTAssertEqual(SpeakerEmbedderHelpers.l2Normalize(v), v)
    }

    func test_cosine_identicalUnitVectors_isOne() {
        let v = SpeakerEmbedderHelpers.l2Normalize([1, 2, 3, 4])
        XCTAssertEqual(SpeakerEmbedderHelpers.cosine(v, v), 1.0, accuracy: 0.0001)
    }

    func test_cosine_orthogonal_isZero() {
        let a: [Float] = [1, 0]
        let b: [Float] = [0, 1]
        XCTAssertEqual(SpeakerEmbedderHelpers.cosine(a, b), 0.0, accuracy: 0.0001)
    }
}
```

- [ ] **Step 2: Run test → fail (undefined)**

Expected: BUILD FAILED

- [ ] **Step 3: Create `Meeting/Identity/SpeakerEmbedderHelpers.swift`**

```swift
import Foundation
import Accelerate

enum SpeakerEmbedderHelpers {
    static func concatenate(_ segments: [[Float]]) -> [Float] {
        var out: [Float] = []
        out.reserveCapacity(segments.reduce(0) { $0 + $1.count })
        for s in segments { out.append(contentsOf: s) }
        return out
    }

    /// Slide a `chunkSamples`-wide window over `audio` with `hopSamples` stride.
    /// Drops trailing tail that's shorter than `chunkSamples`.
    static func chunk(_ audio: [Float], chunkSamples: Int, hopSamples: Int) -> [[Float]] {
        guard audio.count >= chunkSamples else { return [] }
        var chunks: [[Float]] = []
        var start = 0
        while start + chunkSamples <= audio.count {
            chunks.append(Array(audio[start..<(start + chunkSamples)]))
            start += hopSamples
        }
        return chunks
    }

    static func l2Normalize(_ v: [Float]) -> [Float] {
        var sumSq: Float = 0
        vDSP_svesq(v, 1, &sumSq, vDSP_Length(v.count))
        let norm = sqrt(sumSq)
        guard norm > 0 else { return v }
        var divisor = norm
        var out = [Float](repeating: 0, count: v.count)
        vDSP_vsdiv(v, 1, &divisor, &out, 1, vDSP_Length(v.count))
        return out
    }

    /// Cosine similarity for L2-normalized vectors = dot product.
    /// Returns 0 if either vector is empty or sizes mismatch.
    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, a.count > 0 else { return 0 }
        var dot: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        return dot
    }
}
```

- [ ] **Step 4: Run tests**

```
xcodegen generate && \
xcodebuild -project Meeting.xcodeproj -scheme Meeting -destination 'platform=macOS' \
  -only-testing:MeetingTests/SpeakerEmbedderHelpersTests test
```
Expected: PASS (7 tests)

- [ ] **Step 5: Commit**

```bash
git add Meeting/Identity/SpeakerEmbedderHelpers.swift \
        MeetingTests/SpeakerEmbedderHelpersTests.swift Meeting.xcodeproj
git commit -m "add SpeakerEmbedderHelpers (concat/chunk/L2/cosine)"
```

---

## Task 6: SpeakerEmbedder Core ML actor + integration test

**Files:**
- Modify: `Meeting/Identity/SpeakerEmbedder.swift` (replace stub)
- Create: `MeetingTests/SpeakerEmbedderIntegrationTests.swift`
- Create: `MeetingTests/fixtures/two-speaker-5s.wav` (binary asset)

**Audio fixture generation:** ใช้คำสั่ง `sox` หรือ `ffmpeg` สร้าง 5s mono 16kHz WAV ที่มีคนพูด 2 คนตัดกัน — หรือ extract จาก `output.wav` ของ meeting ที่มีอยู่ ผ่าน:

```bash
ffmpeg -i ~/Documents/Meetings/<some-folder>/output.m4a \
  -t 5 -ac 1 -ar 16000 -f wav MeetingTests/fixtures/two-speaker-5s.wav
```

- [ ] **Step 0: Generate test fixture**

```bash
mkdir -p MeetingTests/fixtures
# Pick any existing recording with multiple speakers, e.g.:
ffmpeg -y -i ~/Documents/Meetings/<existing>/output.m4a \
  -t 5 -ac 1 -ar 16000 -f wav MeetingTests/fixtures/two-speaker-5s.wav
```

อัปเดต `project.yml` ให้ MeetingTests bundle รวม fixture:

```yaml
  MeetingTests:
    type: bundle.unit-test
    platform: macOS
    sources:
      - path: MeetingTests
      - path: MeetingTests/fixtures
        type: folder
```

(หาก `fixtures` ถูกตีความเป็น Swift source โดย default, ทำเป็น folder reference เพื่อ copy เป็น resource)

- [ ] **Step 1: Write integration test (skipped if model files missing)**

```swift
// MeetingTests/SpeakerEmbedderIntegrationTests.swift
import XCTest
@testable import Meeting

final class SpeakerEmbedderIntegrationTests: XCTestCase {
    func test_embed_returnsL2NormalizedVector_of192Dim() async throws {
        guard let fixtureURL = Bundle(for: type(of: self))
            .url(forResource: "two-speaker-5s", withExtension: "wav")
        else {
            throw XCTSkip("Fixture missing — run script in task 6 step 0")
        }
        guard SpeakerEmbedder.modelsAvailable() else {
            throw XCTSkip("Pyannote models not downloaded — run LocalProvider transcribe once")
        }

        let audio = try loadWavAs16kMono(fixtureURL)
        let embedder = SpeakerEmbedder()
        try await embedder.loadModels()
        defer { Task { await embedder.unloadModels() } }

        let result = try await embedder.embed(audioSegments: [audio])
        let v = try XCTUnwrap(result, "embedding nil — audio < 3s?")
        XCTAssertEqual(v.count, 192, "pyannote v3 W8A16 should produce 192-dim — argmax bump?")
        let norm = sqrt(v.reduce(into: Float(0)) { $0 += $1 * $1 })
        XCTAssertEqual(norm, 1.0, accuracy: 0.001)
    }

    func test_embed_below3s_returnsNil() async throws {
        guard SpeakerEmbedder.modelsAvailable() else {
            throw XCTSkip("Pyannote models not downloaded")
        }
        // 2s of audio total
        let short: [Float] = [Float](repeating: 0.1, count: 32_000)
        let embedder = SpeakerEmbedder()
        try await embedder.loadModels()
        defer { Task { await embedder.unloadModels() } }

        let result = try await embedder.embed(audioSegments: [short])
        XCTAssertNil(result)
    }

    private func loadWavAs16kMono(_ url: URL) throws -> [Float] {
        // Reuse WhisperKit's AudioProcessor — already 16k mono float
        return try AudioProcessor.loadAudioAsFloatArray(
            fromPath: url.path(percentEncoded: false),
            channelMode: .sumChannels(nil)
        )
    }
}
```

- [ ] **Step 2: Run test → expect skip (or fail at SpeakerEmbedder init/methods)**

Expected: SKIPPED with "Pyannote models not downloaded" if user has not yet run a local transcribe

- [ ] **Step 3: Replace `Meeting/Identity/SpeakerEmbedder.swift` stub with full implementation**

```swift
import Foundation
import CoreML
import Accelerate

actor SpeakerEmbedder {
    static let modelTag = "pyannote-v3-w8a16"

    /// 16kHz × 5s = 80_000 samples per inference chunk.
    private static let chunkSamples = 80_000
    /// 0.5s overlap → hop 72_000.
    private static let hopSamples = 72_000
    /// Minimum total audio per speaker before we'll embed.
    private static let minDurationSeconds: Double = 3.0
    /// Output dim — verified by integration test.
    static let outputDim = 192

    private var preEmbedder: MLModel?
    private var embedder: MLModel?
    private var loadTask: Task<Void, Error>?

    static func modelsAvailable() -> Bool {
        guard let (a, b) = try? modelURLs() else { return false }
        return FileManager.default.fileExists(atPath: a.path(percentEncoded: false))
            && FileManager.default.fileExists(atPath: b.path(percentEncoded: false))
    }

    private static func modelURLs() throws -> (URL, URL) {
        let base = ModelStorage.downloadBase()
            .appendingPathComponent("models/argmaxinc/speakerkit-coreml/speaker_embedder/pyannote-v3/W8A16",
                                    isDirectory: true)
        return (
            base.appendingPathComponent("SpeakerEmbedderPreprocessor.mlmodelc"),
            base.appendingPathComponent("SpeakerEmbedder.mlmodelc")
        )
    }

    func loadModels() async throws {
        if preEmbedder != nil && embedder != nil { return }
        if let existing = loadTask { return try await existing.value }
        let task = Task<Void, Error> {
            let (preURL, embURL) = try Self.modelURLs()
            let cfg = MLModelConfiguration()
            cfg.computeUnits = .cpuAndNeuralEngine
            self.preEmbedder = try await MLModel.load(contentsOf: preURL, configuration: cfg)
            self.embedder = try await MLModel.load(contentsOf: embURL, configuration: cfg)
        }
        loadTask = task
        defer { loadTask = nil }
        try await task.value
    }

    func unloadModels() {
        preEmbedder = nil
        embedder = nil
    }

    /// Returns L2-normalized 192-dim centroid, or nil if total audio < 3s.
    /// `audioSegments` should already be 16kHz mono Float arrays — typically the per-speaker
    /// slices extracted by EmbeddingExtractionQueue.
    func embed(audioSegments: [[Float]]) async throws -> [Float]? {
        let totalSamples = audioSegments.reduce(0) { $0 + $1.count }
        let totalSeconds = Double(totalSamples) / 16_000.0
        guard totalSeconds >= Self.minDurationSeconds else { return nil }

        try await loadModels()
        guard let pre = preEmbedder, let emb = embedder else {
            throw SpeakerEmbedderError.modelsNotLoaded
        }

        let concat = SpeakerEmbedderHelpers.concatenate(audioSegments)
        let chunks = SpeakerEmbedderHelpers.chunk(
            concat,
            chunkSamples: Self.chunkSamples,
            hopSamples: Self.hopSamples
        )
        guard !chunks.isEmpty else { return nil }

        var accum = [Float](repeating: 0, count: Self.outputDim)
        for chunk in chunks {
            let vec = try await embedChunk(chunk, preEmbedder: pre, embedder: emb)
            for i in 0..<Self.outputDim { accum[i] += vec[i] }
        }
        return SpeakerEmbedderHelpers.l2Normalize(accum)
    }

    /// Run one 5s chunk through preprocessor + embedder.
    /// Input names are read from the model's `modelDescription.inputDescriptionsByName`
    /// at runtime — kept tolerant to argmax key rename.
    private func embedChunk(
        _ chunk: [Float],
        preEmbedder pre: MLModel,
        embedder emb: MLModel
    ) async throws -> [Float] {
        // 1. Waveform → MLMultiArray shape [1, 1, samples] float32
        let waveform = try MLMultiArray(shape: [1, 1, NSNumber(value: chunk.count)],
                                        dataType: .float32)
        chunk.withUnsafeBufferPointer { buf in
            for i in 0..<chunk.count { waveform[i] = NSNumber(value: buf[i]) }
        }
        // 2. Preprocessor: expects single input — find its name dynamically
        let preInputName = try Self.firstInputName(pre, contextLabel: "preEmbedder")
        let preInput = try MLDictionaryFeatureProvider(dictionary: [preInputName: waveform])
        let preOutput = try await pre.prediction(from: preInput)
        let preOutputName = try Self.firstOutputName(pre, contextLabel: "preEmbedder")
        guard let features = preOutput.featureValue(for: preOutputName)?.multiArrayValue else {
            throw SpeakerEmbedderError.invalidModelOutput("preEmbedder: \(preOutputName) missing")
        }

        // 3. Embedder expects (speakerMasks, preprocessorOutput) — names also resolved dynamically
        // For our isolate-then-embed simplification: speakerMasks = ones of shape matching frames
        let inputs = emb.modelDescription.inputDescriptionsByName
        guard inputs.count == 2 else {
            throw SpeakerEmbedderError.invalidModelOutput(
                "embedder expected 2 inputs, got \(inputs.count) — argmax changed schema?"
            )
        }
        let maskName = inputs.keys.first { $0.lowercased().contains("mask") }
            ?? inputs.keys.sorted().first!
        let featuresName = inputs.keys.first { $0 != maskName }!

        // Build speakerMasks: shape [1, 1, frames] (single speaker, all-ones)
        // `frames` = last dim of features
        let framesDim = features.shape.last?.intValue ?? 0
        guard framesDim > 0 else {
            throw SpeakerEmbedderError.invalidModelOutput("preEmbedder features have zero frames")
        }
        let masks = try MLMultiArray(shape: [1, 1, NSNumber(value: framesDim)],
                                     dataType: .float32)
        for i in 0..<framesDim { masks[i] = 1.0 }

        let embInput = try MLDictionaryFeatureProvider(dictionary: [
            maskName: masks,
            featuresName: features
        ])
        let embOutput = try await emb.prediction(from: embInput)
        let embOutputName = try Self.firstOutputName(emb, contextLabel: "embedder")
        guard let raw = embOutput.featureValue(for: embOutputName)?.multiArrayValue else {
            throw SpeakerEmbedderError.invalidModelOutput("embedder: \(embOutputName) missing")
        }

        // 4. Flatten + verify dim
        let count = raw.count
        guard count >= Self.outputDim else {
            throw SpeakerEmbedderError.shapeMismatch(expected: Self.outputDim, got: count)
        }
        var out = [Float](repeating: 0, count: Self.outputDim)
        for i in 0..<Self.outputDim { out[i] = raw[i].floatValue }
        return SpeakerEmbedderHelpers.l2Normalize(out)
    }

    private static func firstInputName(_ m: MLModel, contextLabel: String) throws -> String {
        guard let name = m.modelDescription.inputDescriptionsByName.keys.sorted().first else {
            throw SpeakerEmbedderError.invalidModelOutput("\(contextLabel) has no inputs")
        }
        return name
    }

    private static func firstOutputName(_ m: MLModel, contextLabel: String) throws -> String {
        guard let name = m.modelDescription.outputDescriptionsByName.keys.sorted().first else {
            throw SpeakerEmbedderError.invalidModelOutput("\(contextLabel) has no outputs")
        }
        return name
    }
}

enum SpeakerEmbedderError: LocalizedError {
    case modelsNotLoaded
    case invalidModelOutput(String)
    case shapeMismatch(expected: Int, got: Int)

    var errorDescription: String? {
        switch self {
        case .modelsNotLoaded: "Pyannote embedder models not loaded"
        case .invalidModelOutput(let m): "Invalid embedder output: \(m)"
        case .shapeMismatch(let e, let g): "Embedder shape mismatch: expected \(e), got \(g)"
        }
    }
}
```

- [ ] **Step 4: Run integration test (requires manual model download via local transcribe first)**

```
xcodegen generate
# Trigger model download if not already
# Then:
xcodebuild -project Meeting.xcodeproj -scheme Meeting -destination 'platform=macOS' \
  -only-testing:MeetingTests/SpeakerEmbedderIntegrationTests test
```

Expected if models present: PASS (2 tests) — embedding shape = 192, L2 norm = 1.0±0.001
Expected if not: SKIPPED

- [ ] **Step 5: If integration test FAILS shape check (dim != 192)** — STOP, flag to user. argmax may have shipped a new version. Update spec + plan before continuing.

- [ ] **Step 6: Commit**

```bash
git add Meeting/Identity/SpeakerEmbedder.swift \
        MeetingTests/SpeakerEmbedderIntegrationTests.swift \
        MeetingTests/fixtures/two-speaker-5s.wav \
        project.yml Meeting.xcodeproj
git commit -m "SpeakerEmbedder — pyannote v3 Core ML wrapper with isolate-then-embed pipeline"
```

---

## Task 7: IdentitySuggestion + IdentityMatcher scoring

**Files:**
- Create: `Meeting/Identity/IdentitySuggestion.swift`
- Create: `Meeting/Identity/IdentityMatcher.swift`
- Create: `MeetingTests/IdentityMatcherTests.swift`
- Create: `MeetingTests/IdentitySuggestionConfidenceTests.swift`

- [ ] **Step 1: Write matcher tests covering all priors + threshold + mutual exclusion**

```swift
// MeetingTests/IdentityMatcherTests.swift
import XCTest
@testable import Meeting

final class IdentityMatcherTests: XCTestCase {
    func test_embeddingPrior_cosineDotProduct() {
        let v = SpeakerEmbedderHelpers.l2Normalize([1, 2, 3, 4])
        let identity = Identity(
            id: "1", displayName: "X", emails: [],
            centroid: v, sampleSeconds: 10, seenIn: [], meetingCount: 1,
            createdAt: Date(), updatedAt: Date()
        )
        let score = IdentityMatcher.embeddingScore(speaker: v, identity: identity.centroid)
        XCTAssertEqual(score, 1.0, accuracy: 0.001)
    }

    func test_calendarPrior_matchEmail_is1_else0() {
        let ctx = MatchContext(
            attendeeEmails: ["sun@example.com"],
            meetParticipantNames: [],
            meetingFolder: "M"
        )
        let withEmail = Identity(
            id: "1", displayName: "X", emails: ["sun@example.com"],
            centroid: [], sampleSeconds: 0, seenIn: [], meetingCount: 0,
            createdAt: Date(), updatedAt: Date()
        )
        let noEmail = Identity(
            id: "2", displayName: "Y", emails: ["other@example.com"],
            centroid: [], sampleSeconds: 0, seenIn: [], meetingCount: 0,
            createdAt: Date(), updatedAt: Date()
        )
        XCTAssertEqual(IdentityMatcher.calendarPrior(identity: withEmail, context: ctx), 1.0)
        XCTAssertEqual(IdentityMatcher.calendarPrior(identity: noEmail, context: ctx), 0.0)
    }

    func test_meetNamePrior_exact_is1_fuzzy_is07_else0() {
        let ctx = MatchContext(
            attendeeEmails: [],
            meetParticipantNames: ["Sun Sarin", "Pim"],
            meetingFolder: "M"
        )
        let exact = identity(name: "sun sarin")
        let fuzzy = identity(name: "Sunsarine")
        let none  = identity(name: "Aon")
        XCTAssertEqual(IdentityMatcher.meetNamePrior(identity: exact, context: ctx), 1.0)
        XCTAssertEqual(IdentityMatcher.meetNamePrior(identity: fuzzy, context: ctx), 0.7, accuracy: 0.001)
        XCTAssertEqual(IdentityMatcher.meetNamePrior(identity: none,  context: ctx), 0.0)
    }

    func test_recencyPrior_decaysExponentially() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let recent = identity(name: "X", lastSeenDaysAgo: 0, now: now)
        let stale = identity(name: "X", lastSeenDaysAgo: 30, now: now)
        let ancient = identity(name: "X", lastSeenDaysAgo: 90, now: now)
        XCTAssertEqual(IdentityMatcher.recencyPrior(identity: recent, now: now), 1.0, accuracy: 0.01)
        XCTAssertEqual(IdentityMatcher.recencyPrior(identity: stale, now: now), 0.37, accuracy: 0.05)
        XCTAssertEqual(IdentityMatcher.recencyPrior(identity: ancient, now: now), 0.05, accuracy: 0.02)
    }

    func test_compositeScore_blendsAllPriors() {
        // Set up a single identity + speaker with perfect embedding match,
        // identity has matching email + matching meet name.
        let centroid = SpeakerEmbedderHelpers.l2Normalize([1, 2, 3, 4])
        let identity = Identity(
            id: "1", displayName: "Sun Sarin", emails: ["sun@example.com"],
            centroid: centroid, sampleSeconds: 60,
            seenIn: ["yesterday"], meetingCount: 5,
            createdAt: Date(), updatedAt: Date().addingTimeInterval(-86_400)  // 1 day ago
        )
        let speakerEmb = SpeakerEmbedding(
            speakerID: SpeakerID.diarized(0),
            centroid: centroid,
            sampleSeconds: 30
        )
        let ctx = MatchContext(
            attendeeEmails: ["sun@example.com"],
            meetParticipantNames: ["Sun Sarin"],
            meetingFolder: "M"
        )
        let score = IdentityMatcher.compositeScore(
            speaker: speakerEmb, identity: identity, context: ctx, now: Date()
        )
        // 0.65 * 1.0 + 0.20 * 1.0 + 0.10 * 1.0 + 0.05 * ~0.97
        XCTAssertEqual(score, 1.0, accuracy: 0.02)
    }

    func test_match_filtersBelowThreshold() {
        let centroid = SpeakerEmbedderHelpers.l2Normalize([1, 2, 3, 4])
        let oppositeCentroid = SpeakerEmbedderHelpers.l2Normalize([-1, -2, -3, -4])
        let identity = Identity(
            id: "1", displayName: "X", emails: [],
            centroid: oppositeCentroid, sampleSeconds: 60,
            seenIn: ["A"], meetingCount: 1,
            createdAt: Date(), updatedAt: Date()
        )
        let speakerEmb = SpeakerEmbedding(
            speakerID: SpeakerID.diarized(0), centroid: centroid, sampleSeconds: 30
        )
        let suggestions = IdentityMatcher.match(
            embeddings: [speakerEmb],
            identities: [identity],
            context: MatchContext(attendeeEmails: [], meetParticipantNames: [], meetingFolder: "M"),
            rejected: [],
            config: MatchingConfig(),
            now: Date()
        )
        XCTAssertTrue(suggestions.isEmpty, "negative cosine — below threshold")
    }

    func test_match_mutualExclusion_oneIdentityPerSpeaker() {
        let c1 = SpeakerEmbedderHelpers.l2Normalize([1, 0, 0, 0])
        let c2 = SpeakerEmbedderHelpers.l2Normalize([0, 1, 0, 0])

        let identity1 = identity(name: "A", centroid: c1)
        // Two speakers with similar embeddings; both want identity1 ideally
        let speaker0 = SpeakerEmbedding(speakerID: SpeakerID.diarized(0), centroid: c1, sampleSeconds: 60)
        let speaker1 = SpeakerEmbedding(speakerID: SpeakerID.diarized(1), centroid: c2, sampleSeconds: 60)

        let suggestions = IdentityMatcher.match(
            embeddings: [speaker0, speaker1],
            identities: [identity1],
            context: MatchContext(attendeeEmails: [], meetParticipantNames: [], meetingFolder: "M"),
            rejected: [],
            config: MatchingConfig(),
            now: Date()
        )
        let identityIDs = Set(suggestions.map { $0.identityID })
        XCTAssertLessThanOrEqual(identityIDs.count, 1, "identity1 should be claimed once max")
    }

    func test_match_skipsRejected() {
        let c = SpeakerEmbedderHelpers.l2Normalize([1, 2, 3, 4])
        let identity = identity(name: "A", centroid: c)
        let speaker = SpeakerEmbedding(speakerID: SpeakerID.diarized(0), centroid: c, sampleSeconds: 60)
        let suggestions = IdentityMatcher.match(
            embeddings: [speaker],
            identities: [identity],
            context: MatchContext(attendeeEmails: [], meetParticipantNames: [], meetingFolder: "M"),
            rejected: [Rejection(speakerID: SpeakerID.diarized(0), identityID: identity.id)],
            config: MatchingConfig(),
            now: Date()
        )
        XCTAssertTrue(suggestions.isEmpty)
    }

    // MARK: - Helpers
    private func identity(
        name: String,
        centroid: [Float] = [],
        emails: [String] = [],
        lastSeenDaysAgo days: Double = 0,
        now: Date = Date()
    ) -> Identity {
        let updated = now.addingTimeInterval(-days * 86_400)
        return Identity(
            id: UUID().uuidString,
            displayName: name,
            emails: emails,
            centroid: centroid,
            sampleSeconds: 60,
            seenIn: ["X"],
            meetingCount: 1,
            createdAt: updated,
            updatedAt: updated
        )
    }
}
```

- [ ] **Step 2: Write confidence percent tests**

```swift
// MeetingTests/IdentitySuggestionConfidenceTests.swift
import XCTest
@testable import Meeting

final class IdentitySuggestionConfidenceTests: XCTestCase {
    func test_threshold_maps_to50pct() {
        XCTAssertEqual(IdentityMatcher.confidencePercent(0.55), 50)
    }
    func test_perfect_maps_to99pct() {
        XCTAssertEqual(IdentityMatcher.confidencePercent(1.0), 99)
    }
    func test_belowThreshold_clamps_to50pct() {
        XCTAssertEqual(IdentityMatcher.confidencePercent(0.3), 50)
    }
    func test_aboveOne_clamps_to99pct() {
        XCTAssertEqual(IdentityMatcher.confidencePercent(1.5), 99)
    }
}
```

- [ ] **Step 3: Run tests → fail (matcher undefined)**

Expected: BUILD FAILED

- [ ] **Step 4: Create `Meeting/Identity/IdentitySuggestion.swift`**

```swift
import Foundation

struct IdentitySuggestion: Hashable, Sendable, Identifiable {
    let speakerID: SpeakerID
    let identityID: String
    let identityDisplayName: String
    let score: Double
    let confidencePercent: Int
    var id: String { "\(speakerID.rawValue):\(identityID)" }
}

struct MatchContext: Sendable {
    let attendeeEmails: Set<String>      // lowercased
    let meetParticipantNames: [String]
    let meetingFolder: String

    init(attendeeEmails: [String], meetParticipantNames: [String], meetingFolder: String) {
        self.attendeeEmails = Set(attendeeEmails.map { $0.lowercased() })
        self.meetParticipantNames = meetParticipantNames
        self.meetingFolder = meetingFolder
    }
}

struct MatchingConfig: Sendable {
    var minSuggestScore: Double = 0.55
    var highConfidenceScore: Double = 0.75
    var maxSuggestionsPerSpeaker: Int = 3
    var embeddingWeight: Double = 0.65
    var calendarWeight: Double = 0.20
    var meetNameWeight: Double = 0.10
    var recencyWeight: Double = 0.05
    var recencyDecayDays: Double = 30
}
```

- [ ] **Step 5: Create `Meeting/Identity/IdentityMatcher.swift`**

```swift
import Foundation

enum IdentityMatcher {
    static func embeddingScore(speaker: [Float], identity: [Float]) -> Double {
        let raw = SpeakerEmbedderHelpers.cosine(speaker, identity)
        return Double(max(0, raw))
    }

    static func calendarPrior(identity: Identity, context: MatchContext) -> Double {
        for e in identity.emails where context.attendeeEmails.contains(e) {
            return 1.0
        }
        return 0.0
    }

    static func meetNamePrior(identity: Identity, context: MatchContext) -> Double {
        let target = identity.displayName.lowercased().trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return 0 }
        var bestFuzzy: Double = 0
        for name in context.meetParticipantNames {
            let lc = name.lowercased().trimmingCharacters(in: .whitespaces)
            if lc == target { return 1.0 }
            let ratio = 1.0 - Double(levenshtein(lc, target)) / Double(max(lc.count, target.count, 1))
            if ratio >= 0.85 {
                bestFuzzy = max(bestFuzzy, 0.7)
            }
        }
        return bestFuzzy
    }

    static func recencyPrior(identity: Identity, now: Date) -> Double {
        let days = max(0, now.timeIntervalSince(identity.updatedAt) / 86_400)
        return min(1.0, exp(-days / 30))
    }

    static func compositeScore(
        speaker: SpeakerEmbedding,
        identity: Identity,
        context: MatchContext,
        config: MatchingConfig = MatchingConfig(),
        now: Date
    ) -> Double {
        let e = embeddingScore(speaker: speaker.centroid, identity: identity.centroid)
        let c = calendarPrior(identity: identity, context: context)
        let n = meetNamePrior(identity: identity, context: context)
        let r = recencyPrior(identity: identity, now: now)
        return config.embeddingWeight * e
             + config.calendarWeight * c
             + config.meetNameWeight * n
             + config.recencyWeight * r
    }

    static func confidencePercent(_ score: Double) -> Int {
        let s = max(0.55, min(1.0, score))
        let normalized = (s - 0.55) / (1.0 - 0.55)
        return Int(50 + normalized * 49)
    }

    /// Returns suggestions sorted by score desc. Applies greedy mutual exclusion:
    /// one identity claimed at most once across speakers in a single meeting.
    static func match(
        embeddings: [SpeakerEmbedding],
        identities: [Identity],
        context: MatchContext,
        rejected: [Rejection],
        config: MatchingConfig = MatchingConfig(),
        now: Date
    ) -> [IdentitySuggestion] {
        // 1. Build all (speaker, identity) candidate scores above threshold
        struct Candidate {
            let speakerID: SpeakerID
            let identity: Identity
            let score: Double
        }
        let rejectedSet = Set(rejected.map { "\($0.speakerID.rawValue):\($0.identityID)" })

        var candidates: [Candidate] = []
        for speaker in embeddings {
            for identity in identities {
                let key = "\(speaker.speakerID.rawValue):\(identity.id)"
                guard !rejectedSet.contains(key) else { continue }
                let s = compositeScore(
                    speaker: speaker, identity: identity,
                    context: context, config: config, now: now
                )
                if s >= config.minSuggestScore {
                    candidates.append(Candidate(speakerID: speaker.speakerID, identity: identity, score: s))
                }
            }
        }

        // 2. Greedy assignment: pick highest, claim both, repeat
        candidates.sort { $0.score > $1.score }
        var claimedSpeakers = Set<SpeakerID>()
        var claimedIdentities = Set<String>()
        var suggestions: [IdentitySuggestion] = []
        for c in candidates {
            if claimedSpeakers.contains(c.speakerID) || claimedIdentities.contains(c.identity.id) {
                continue
            }
            claimedSpeakers.insert(c.speakerID)
            claimedIdentities.insert(c.identity.id)
            suggestions.append(IdentitySuggestion(
                speakerID: c.speakerID,
                identityID: c.identity.id,
                identityDisplayName: c.identity.displayName,
                score: c.score,
                confidencePercent: confidencePercent(c.score)
            ))
        }
        return suggestions
    }

    private static func levenshtein(_ a: String, _ b: String) -> Int {
        if a == b { return 0 }
        let s = Array(a); let t = Array(b)
        if s.isEmpty { return t.count }
        if t.isEmpty { return s.count }
        var prev = Array(0...t.count)
        var curr = [Int](repeating: 0, count: t.count + 1)
        for i in 1...s.count {
            curr[0] = i
            for j in 1...t.count {
                let cost = s[i - 1] == t[j - 1] ? 0 : 1
                curr[j] = min(curr[j - 1] + 1, prev[j] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &curr)
        }
        return prev[t.count]
    }
}
```

- [ ] **Step 6: Run tests**

```
xcodegen generate && \
xcodebuild -project Meeting.xcodeproj -scheme Meeting -destination 'platform=macOS' \
  -only-testing:MeetingTests/IdentityMatcherTests \
  -only-testing:MeetingTests/IdentitySuggestionConfidenceTests test
```
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add Meeting/Identity/IdentityMatcher.swift Meeting/Identity/IdentitySuggestion.swift \
        MeetingTests/IdentityMatcherTests.swift MeetingTests/IdentitySuggestionConfidenceTests.swift \
        Meeting.xcodeproj
git commit -m "IdentityMatcher — composite score with greedy mutual exclusion"
```

---

## Task 8: EmbeddingExtractionQueue actor

**Files:**
- Create: `Meeting/Identity/EmbeddingExtractionQueue.swift`

อันนี้เป็น **integration glue** — `MeetingsLibrary` ปลายทาง, แต่ separate file ให้ test กว้างต่อจาก step ถัดไปง่ายขึ้น

- [ ] **Step 1: Create skeleton**

```swift
// Meeting/Identity/EmbeddingExtractionQueue.swift
import Foundation
import WhisperKit  // for AudioProcessor

actor EmbeddingExtractionQueue {
    private let embedder = SpeakerEmbedder()
    private var pending: [URL] = []   // meeting folder URLs
    private var processing: URL?
    private var task: Task<Void, Never>?

    /// Called by MeetingsLibrary after each load — idempotent: if already pending/processing,
    /// no-op.
    func enqueue(meetingFolder: URL) {
        guard processing != meetingFolder else { return }
        guard !pending.contains(meetingFolder) else { return }
        pending.append(meetingFolder)
        if task == nil { task = Task { await self.drain() } }
    }

    private func drain() async {
        while let next = pending.first {
            pending.removeFirst()
            processing = next
            await process(folder: next)
            processing = nil
        }
        task = nil
        await embedder.unloadModels()
    }

    private func process(folder: URL) async {
        // Skip if already done
        if (try? MeetingEmbeddingsFile.read(from: folder)) != nil {
            return
        }
        do {
            try await runExtraction(folder: folder)
        } catch {
            NSLog("[Meeting/Identity] extraction failed for %@: %@",
                  folder.lastPathComponent, String(describing: error))
            // Persist failure flag so we don't loop
            let file = MeetingEmbeddingsFile(
                schemaVersion: 1,
                embedderModel: SpeakerEmbedder.modelTag,
                embeddings: [],
                rejectedIdentities: [],
                embeddingFailed: true
            )
            try? file.write(to: folder)
        }
    }

    private func runExtraction(folder: URL) async throws {
        // 1. Read merged transcript
        let txURL = folder.appendingPathComponent("transcript.json")
        let txData = try Data(contentsOf: txURL)
        let transcript = try JSONDecoder().decode(MergedTranscript.self, from: txData)

        // 2. Load output.m4a (16 kHz mono float)
        let audioURL = folder.appendingPathComponent("output.m4a")
        guard FileManager.default.fileExists(atPath: audioURL.path(percentEncoded: false)) else {
            // No diarized output to embed — skip (mic-only meetings will hit this)
            throw EmbeddingExtractionError.noOutputAudio
        }
        let audio = try AudioProcessor.loadAudioAsFloatArray(
            fromPath: audioURL.path(percentEncoded: false),
            channelMode: .sumChannels(nil)
        )
        let sampleRate: Double = 16_000

        // 3. Group segments by speakerID, drop overlaps (±200ms boundary inside each segment)
        let speakerGroups = Dictionary(grouping: transcript.segments) { $0.speaker }
            .filter { $0.key != .me }   // skip mic stream

        // 4. Per speaker: slice audio, embed
        var embeddings: [SpeakerEmbedding] = []
        for (speakerID, segments) in speakerGroups {
            let slices = sliceAudio(audio, segments: segments,
                                    allSegments: transcript.segments,
                                    sampleRate: sampleRate)
            let totalSamples = slices.reduce(0) { $0 + $1.count }
            let totalSeconds = Double(totalSamples) / sampleRate
            guard totalSeconds >= 3.0 else { continue }
            if let centroid = try await embedder.embed(audioSegments: slices) {
                embeddings.append(SpeakerEmbedding(
                    speakerID: speakerID,
                    centroid: centroid,
                    sampleSeconds: totalSeconds
                ))
            }
        }

        // 5. Merge with any existing file (preserve rejectedIdentities if user reset embeddings only)
        var existing = (try? MeetingEmbeddingsFile.read(from: folder)) ?? MeetingEmbeddingsFile(
            schemaVersion: 1,
            embedderModel: SpeakerEmbedder.modelTag,
            embeddings: [],
            rejectedIdentities: [],
            embeddingFailed: false
        )
        existing.embeddings = embeddings
        existing.embeddingFailed = false
        try existing.write(to: folder)
    }

    /// For each segment of `speakerID`, slice audio[start:end] **after** subtracting overlap
    /// with other speakers' segments + a 200ms safety margin.
    private func sliceAudio(
        _ audio: [Float],
        segments: [TranscriptSegment],
        allSegments: [TranscriptSegment],
        sampleRate: Double
    ) -> [[Float]] {
        let margin: TimeInterval = 0.2
        var slices: [[Float]] = []
        let speakerIDs = Set(segments.map { $0.speaker })
        for seg in segments {
            var start = seg.start + margin
            var end = seg.end - margin
            if end <= start { continue }
            // Punch out overlapping other-speaker spans
            let conflicts = allSegments.filter { other in
                !speakerIDs.contains(other.speaker)
                    && other.end > start && other.start < end
            }
            // Simple approach: skip seg entirely if any conflict overlaps > 30% of its duration
            let conflictCoverage = conflicts.reduce(0.0) { acc, c in
                acc + (min(end, c.end) - max(start, c.start))
            }
            if conflictCoverage / (end - start) > 0.3 { continue }

            let startSample = Int(start * sampleRate)
            let endSample = min(audio.count, Int(end * sampleRate))
            guard endSample > startSample else { continue }
            slices.append(Array(audio[startSample..<endSample]))
        }
        return slices
    }
}

enum EmbeddingExtractionError: LocalizedError {
    case noOutputAudio
    var errorDescription: String? {
        switch self {
        case .noOutputAudio: "No output.m4a found in meeting folder"
        }
    }
}
```

- [ ] **Step 2: Run xcodegen + compile-only check**

```
xcodegen generate && \
xcodebuild -project Meeting.xcodeproj -scheme Meeting -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build
```
Expected: BUILD SUCCEEDED

(Note: `CODE_SIGN_IDENTITY=-` here is only for the compile check — never run/test the app with this; spec memory feedback flagged it as broken for TCC.)

- [ ] **Step 3: Commit**

```bash
git add Meeting/Identity/EmbeddingExtractionQueue.swift Meeting.xcodeproj
git commit -m "EmbeddingExtractionQueue — serial actor that embeds per-speaker audio"
```

---

## Task 9: MeetingsLibrary integration — load + apply/reject suggestion

**Files:**
- Modify: `Meeting/Library/MeetingRecord.swift`
- Modify: `Meeting/Library/MeetingsLibrary.swift`

- [ ] **Step 1: Add `identitySuggestions` to `MeetingRecord`**

ใน `MeetingRecord.swift` เพิ่ม property (non-Codable, in-memory):

```swift
extension MeetingRecord {
    var identitySuggestionsKey: String { folder.lastPathComponent }
}
```

หรือดีกว่า — เพิ่มเป็น stored property ใน struct:

แก้ `struct MeetingRecord` เพิ่ม:

```swift
var identitySuggestions: [IdentitySuggestion] = []
```

(Codable จะข้ามถ้าเขียน custom Codable หรือ marker ไว้ — แต่ MeetingRecord ไม่ persist เป็น JSON อยู่แล้ว ดังนั้นใส่ default value แล้ว `init(from decoder:)` จะใช้ default หาก decoder ไม่ supply ค่า)

ถ้า MeetingRecord เป็น manually-constructed (ไม่ใช่ Codable) ก็แค่เพิ่ม field — ดู file โดยตรงเพื่อยืนยัน:

```bash
head -60 Meeting/Library/MeetingRecord.swift
```

ปรับให้ตรงกับโครงสร้างที่มี — ถ้า `MeetingRecord` ใช้ memberwise init ทั่วทั้ง codebase ต้องเพิ่ม default หรือ update call sites

- [ ] **Step 2: Modify `MeetingsLibrary.loadRecord(...)` ให้คำนวณ suggestions**

หา `loadRecord(...)` แล้วเพิ่มหลังจาก parse speakers.json + calendar.json + meet_participants.json:

```swift
// ใน MeetingsLibrary.loadRecord(...)
// หลังจาก speakers/calendar/meetParticipants พร้อม:

var identitySuggestions: [IdentitySuggestion] = []
if let store = identityStore,
   let embFile = try? MeetingEmbeddingsFile.read(from: folder),
   !embFile.embeddings.isEmpty,
   embFile.embedderModel == store.embedderModel {

    let attendeeEmails: [String] = calendarEvent?.attendees.compactMap { $0.email } ?? []
    let ctx = MatchContext(
        attendeeEmails: attendeeEmails,
        meetParticipantNames: meetParticipants,
        meetingFolder: folder.lastPathComponent
    )
    identitySuggestions = IdentityMatcher.match(
        embeddings: embFile.embeddings,
        identities: store.identities,
        context: ctx,
        rejected: embFile.rejectedIdentities,
        config: matchingConfig,
        now: Date()
    )
} else {
    // Trigger extraction in background — fire-and-forget; matcher will pick up next scan
    if hasTranscript, let queue = embeddingQueue {
        Task { await queue.enqueue(meetingFolder: folder) }
    }
}

// แล้วใส่ identitySuggestions เข้า MeetingRecord ที่สร้างคืน
```

แก้ `MeetingsLibrary` init เพื่อรับ dependencies:

```swift
@MainActor
final class MeetingsLibrary: ObservableObject {
    // ... existing ...
    private let identityStore: IdentityStore?
    private let embeddingQueue: EmbeddingExtractionQueue?
    private let matchingConfig: MatchingConfig

    init(
        meetingsRoot: URL,
        identityStore: IdentityStore? = nil,
        embeddingQueue: EmbeddingExtractionQueue? = nil,
        matchingConfig: MatchingConfig = MatchingConfig()
    ) {
        // ... existing init body ...
        self.identityStore = identityStore
        self.embeddingQueue = embeddingQueue
        self.matchingConfig = matchingConfig
    }
}
```

- [ ] **Step 3: Add `applyIdentitySuggestion` / `rejectIdentitySuggestion`**

```swift
extension MeetingsLibrary {
    /// User confirms speaker_N == identity_X. Updates speakers.json (displayName + identityID)
    /// and updates the global identity centroid via running-mean.
    func applyIdentitySuggestion(_ suggestion: IdentitySuggestion, meeting: MeetingRecord.ID) {
        guard let store = identityStore else { return }
        guard let m = meetings.first(where: { $0.id == meeting }) else { return }
        guard let embFile = try? MeetingEmbeddingsFile.read(from: m.folder) else { return }
        guard let emb = embFile.embeddings.first(where: { $0.speakerID == suggestion.speakerID }) else { return }
        guard let identity = store.identities.first(where: { $0.id == suggestion.identityID }) else { return }

        // 1. Update speaker profile
        updateSpeaker(meeting: meeting, speakerID: suggestion.speakerID) { profile in
            profile.displayName = identity.displayName
            profile.identityID = identity.id
            if let attendeeEmail = identity.emails.first {
                profile.email = attendeeEmail
            }
        }
        // 2. Update identity centroid (running mean)
        store.updateCentroid(
            id: identity.id,
            newCentroid: emb.centroid,
            newSampleSeconds: emb.sampleSeconds,
            meetingFolder: m.folder.lastPathComponent
        )
        // 3. rescan triggered by updateSpeaker
    }

    /// User dismisses suggestion. Appended to per-meeting rejection log so we won't suggest
    /// the same identity for this speaker again.
    func rejectIdentitySuggestion(_ suggestion: IdentitySuggestion, meeting: MeetingRecord.ID) {
        guard let m = meetings.first(where: { $0.id == meeting }) else { return }
        var embFile = (try? MeetingEmbeddingsFile.read(from: m.folder)) ?? MeetingEmbeddingsFile(
            schemaVersion: 1,
            embedderModel: SpeakerEmbedder.modelTag,
            embeddings: [],
            rejectedIdentities: [],
            embeddingFailed: false
        )
        embFile.appendRejection(Rejection(
            speakerID: suggestion.speakerID,
            identityID: suggestion.identityID
        ))
        try? embFile.write(to: m.folder)
        rescan()
    }

    /// User manually maps a speaker → person (not from suggestion). Embed + create
    /// or reuse identity by displayName / email match.
    func createOrReuseIdentity(
        speakerID: SpeakerID,
        displayName: String,
        email: String?,
        meeting: MeetingRecord.ID
    ) {
        guard let store = identityStore else { return }
        guard let m = meetings.first(where: { $0.id == meeting }) else { return }
        guard let embFile = try? MeetingEmbeddingsFile.read(from: m.folder),
              let emb = embFile.embeddings.first(where: { $0.speakerID == speakerID }) else {
            // Embedding not ready yet — just update displayName, identity will be created
            // on next manual edit after embedding is extracted
            updateSpeaker(meeting: meeting, speakerID: speakerID) { profile in
                profile.displayName = displayName
                profile.email = email
            }
            return
        }
        // Try to reuse by email or displayName (case-insensitive)
        let lowerName = displayName.lowercased()
        let lowerEmail = email?.lowercased()
        let existing = store.identities.first { ident in
            if let e = lowerEmail, ident.emails.contains(e) { return true }
            return ident.displayName.lowercased() == lowerName
        }
        let identityID: String
        if let existing {
            store.updateCentroid(
                id: existing.id,
                newCentroid: emb.centroid,
                newSampleSeconds: emb.sampleSeconds,
                meetingFolder: m.folder.lastPathComponent
            )
            if let lowerEmail, !existing.emails.contains(lowerEmail) {
                store.addEmail(id: existing.id, email: lowerEmail)
            }
            identityID = existing.id
        } else {
            identityID = store.create(
                displayName: displayName,
                email: email,
                centroid: emb.centroid,
                sampleSeconds: emb.sampleSeconds,
                meetingFolder: m.folder.lastPathComponent
            )
        }
        updateSpeaker(meeting: meeting, speakerID: speakerID) { profile in
            profile.displayName = displayName
            profile.identityID = identityID
            profile.email = email
        }
    }
}
```

- [ ] **Step 4: Compile + run all existing tests to ensure no breakage**

```
xcodegen generate && \
xcodebuild -project Meeting.xcodeproj -scheme Meeting -destination 'platform=macOS' test
```

Expected: ALL PASS — `MeetingsLibrary` init call sites รับ default `identityStore: nil` ดังนั้น existing test ของ MeetingsLibrary ไม่กระทบ

- [ ] **Step 5: Commit**

```bash
git add Meeting/Library/MeetingsLibrary.swift Meeting/Library/MeetingRecord.swift \
        Meeting.xcodeproj
git commit -m "MeetingsLibrary — load identity suggestions + apply/reject + createOrReuseIdentity"
```

---

## Task 10: AppState + AppEnvironment wiring

**Files:**
- Modify: `Meeting/App/AppState.swift`
- Modify: `Meeting/App/AppEnvironment.swift`
- Modify: `Meeting/App/AppPreferences.swift`

- [ ] **Step 1: Add prefs**

แก้ `AppPreferences.swift` — เพิ่มสอง prefs:

```swift
@AppStorage("identitySuggestionsEnabled") var identitySuggestionsEnabled: Bool = true
@AppStorage("identityMinSuggestScore") var identityMinSuggestScore: Double = 0.55
```

- [ ] **Step 2: Add IdentityStore + EmbeddingExtractionQueue ใน AppState**

```swift
@MainActor
final class AppState: ObservableObject {
    // ... existing ...
    let identityStore: IdentityStore
    let embeddingQueue: EmbeddingExtractionQueue

    init() {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("dev.fluke.meeting", isDirectory: true)
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        let identityStore = IdentityStore(fileURL: appSupport.appendingPathComponent("identities.json"))
        let embeddingQueue = EmbeddingExtractionQueue()

        self.identityStore = identityStore
        self.embeddingQueue = embeddingQueue

        let prefs = AppPreferences()
        let config = MatchingConfig(
            minSuggestScore: prefs.identityMinSuggestScore
        )

        self.library = MeetingsLibrary(
            meetingsRoot: ...,
            identityStore: prefs.identitySuggestionsEnabled ? identityStore : nil,
            embeddingQueue: embeddingQueue,
            matchingConfig: config
        )
        // ... rest of existing init ...
    }
}
```

- [ ] **Step 3: Add env keys ใน AppEnvironment.swift**

```swift
private struct IdentityStoreKey: EnvironmentKey {
    static let defaultValue: IdentityStore? = nil
}

private struct EmbeddingQueueKey: EnvironmentKey {
    static let defaultValue: EmbeddingExtractionQueue? = nil
}

extension EnvironmentValues {
    var identityStore: IdentityStore? {
        get { self[IdentityStoreKey.self] }
        set { self[IdentityStoreKey.self] = newValue }
    }
    var embeddingQueue: EmbeddingExtractionQueue? {
        get { self[EmbeddingQueueKey.self] }
        set { self[EmbeddingQueueKey.self] = newValue }
    }
}
```

แก้ `appEnvironment(state:)` view modifier ให้ inject ทั้งสอง:

```swift
.environment(\.identityStore, state.identityStore)
.environment(\.embeddingQueue, state.embeddingQueue)
```

- [ ] **Step 4: Compile-check**

```
xcodegen generate && \
xcodebuild -project Meeting.xcodeproj -scheme Meeting -destination 'platform=macOS' build
```
Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git add Meeting/App/AppState.swift Meeting/App/AppEnvironment.swift Meeting/App/AppPreferences.swift \
        Meeting.xcodeproj
git commit -m "AppState — wire IdentityStore + EmbeddingExtractionQueue into environment"
```

---

## Task 11: TranscriptionSession hook (enqueue after diarize)

**Files:**
- Modify: `Meeting/Transcribe/TranscriptionSession.swift`

- [ ] **Step 1: Add embedding queue dependency**

ดู constructor ของ `TranscriptionSession` แล้วเพิ่ม optional `embeddingQueue: EmbeddingExtractionQueue?`:

```swift
init(
    provider: TranscriptionProvider,
    embeddingQueue: EmbeddingExtractionQueue? = nil,
    // ... existing params
) {
    self.embeddingQueue = embeddingQueue
    // ...
}
```

- [ ] **Step 2: Enqueue หลัง diarize เสร็จ**

ใน `run(meetingFolder:expectedSpeakers:)` หลังจาก write `transcript.json` เสร็จ เพิ่ม:

```swift
// After transcript.json + speakers.json are written:
if let queue = embeddingQueue {
    Task { await queue.enqueue(meetingFolder: meetingFolder) }
}
```

- [ ] **Step 3: ใน AppState ส่ง embeddingQueue เข้า TranscriptionSession**

แก้ตำแหน่งที่ instantiate `TranscriptionSession` ใน `AppState` ให้ pass `embeddingQueue: self.embeddingQueue`

- [ ] **Step 4: Compile + smoke test**

```
xcodebuild -project Meeting.xcodeproj -scheme Meeting -destination 'platform=macOS' build
```

- [ ] **Step 5: Commit**

```bash
git add Meeting/Transcribe/TranscriptionSession.swift Meeting/App/AppState.swift
git commit -m "TranscriptionSession — enqueue embedding extraction after diarize"
```

---

## Task 12: Transcript Viewer — suggestion chip per speaker

**Files:**
- Modify: `Meeting/Transcribe/TranscriptViewerView.swift`

- [ ] **Step 1: Locate Speakers card section + grep for where SpeakerProfile chip is rendered**

```bash
grep -n "speakerProfiles\|SpeakerProfile\|attendeeRow" Meeting/Transcribe/TranscriptViewerView.swift | head
```

- [ ] **Step 2: Add suggestion chip view**

ภายใน `TranscriptViewerView` (หรือ subview ที่ render speaker chip) เพิ่ม view ใต้ชื่อ speaker:

```swift
@Environment(\.identityStore) private var identityStore
@EnvironmentObject private var library: MeetingsLibrary

@ViewBuilder
private func suggestionChip(for speakerID: SpeakerID, in meeting: MeetingRecord) -> some View {
    let suggestions = meeting.identitySuggestions.filter { $0.speakerID == speakerID }
    if let top = suggestions.first {
        HStack(spacing: 6) {
            Image(systemName: "wand.and.stars")
                .foregroundColor(.brandAccent)
            Text("suggested: \(top.identityDisplayName) · \(top.confidencePercent)%")
                .font(.caption)
                .foregroundColor(.textDim)
            Spacer(minLength: 4)
            Button(action: { confirm(top, meeting: meeting) }) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.brandSuccess)
            }
            .buttonStyle(.plain)
            .help("Confirm")
            Button(action: { reject(top, meeting: meeting) }) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.textFaint)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
            if suggestions.count > 1 {
                Menu {
                    ForEach(Array(suggestions.dropFirst().prefix(2)), id: \.id) { s in
                        Button("\(s.identityDisplayName) · \(s.confidencePercent)%") {
                            confirm(s, meeting: meeting)
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundColor(.textFaint)
                }
                .menuStyle(.borderlessButton)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.brandAccent.opacity(0.08)))
    }
}

private func confirm(_ s: IdentitySuggestion, meeting: MeetingRecord) {
    library.applyIdentitySuggestion(s, meeting: meeting.id)
}

private func reject(_ s: IdentitySuggestion, meeting: MeetingRecord) {
    library.rejectIdentitySuggestion(s, meeting: meeting.id)
}
```

แล้วเรียก `suggestionChip(for: profile.id, in: meeting)` ใต้ chip ของ speaker ที่ยังไม่มี displayName ที่ user ตั้งไว้ (i.e. ที่ displayName == `speaker_N`):

```swift
if profile.displayName.hasPrefix("speaker_") {
    suggestionChip(for: profile.id, in: meeting)
}
```

- [ ] **Step 3: Compile + manual smoke (run app, open meeting ที่มี suggestion)**

```
xcodebuild -project Meeting.xcodeproj -scheme Meeting -destination 'platform=macOS' build
```

- [ ] **Step 4: Commit**

```bash
git add Meeting/Transcribe/TranscriptViewerView.swift
git commit -m "Transcript Viewer — inline suggestion chip under speaker_N"
```

---

## Task 13: Transcript Viewer — top banner for batch summary

**Files:**
- Modify: `Meeting/Transcribe/TranscriptViewerView.swift`

- [ ] **Step 1: Add @State for banner dismissal + banner view**

```swift
@State private var bannerDismissed = false

@ViewBuilder
private func suggestionBanner(meeting: MeetingRecord) -> some View {
    let count = meeting.identitySuggestions.count
    if count >= 2 && !bannerDismissed {
        HStack(spacing: 8) {
            Image(systemName: "lightbulb")
            Text("\(count) suggestions พบจาก meeting อื่น")
            Spacer()
            Button("ดู") {
                // Defer to scroll-anchor on Speakers card — simple impl: no-op for V1
            }
            .buttonStyle(.borderless)
            Button("ปิด") { bannerDismissed = true }
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.brandAccent.opacity(0.1))
    }
}
```

- [ ] **Step 2: Render banner ด้านบน TranscriptViewerView body**

หา top of body หลัก แล้วใส่:

```swift
suggestionBanner(meeting: meeting)
```

- [ ] **Step 3: Compile + commit**

```
xcodebuild -project Meeting.xcodeproj -scheme Meeting -destination 'platform=macOS' build
```

```bash
git add Meeting/Transcribe/TranscriptViewerView.swift
git commit -m "Transcript Viewer — top banner when ≥2 suggestions present"
```

---

## Task 14: Settings UI — toggle + threshold + manage modal

**Files:**
- Modify: `Meeting/App/SettingsScene.swift` (or wherever Settings scene lives — locate via grep)
- New (if not split out): inline in same file

- [ ] **Step 1: Locate Settings scene**

```bash
grep -rln "Settings(" Meeting/App/ Meeting/
```

- [ ] **Step 2: Add Identity Matching Section**

```swift
struct IdentityMatchingSettingsSection: View {
    @AppStorage("identitySuggestionsEnabled") private var enabled: Bool = true
    @AppStorage("identityMinSuggestScore") private var minScore: Double = 0.55
    @Environment(\.identityStore) private var store
    @State private var showingManage = false
    @State private var confirmingReset = false

    var body: some View {
        Section("Identity matching") {
            Toggle("Suggest speakers from past meetings", isOn: $enabled)

            HStack {
                Text("Suggestion threshold")
                Slider(value: $minScore, in: 0.45...0.70, step: 0.05) {
                    Text("Threshold")
                } minimumValueLabel: {
                    Text("Aggressive").font(.caption)
                } maximumValueLabel: {
                    Text("Conservative").font(.caption)
                }
            }
            .disabled(!enabled)

            HStack {
                if let store {
                    Text("Stored identities: \(store.identities.count)")
                }
                Spacer()
                Button("Manage…") { showingManage = true }
                Button("Reset all…") { confirmingReset = true }
                    .foregroundColor(.recordRed)
            }
        }
        .sheet(isPresented: $showingManage) {
            ManageIdentitiesView()
        }
        .alert("Reset all identities?", isPresented: $confirmingReset) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) {
                store?.reset()
                // also wipe per-meeting embeddings.json — best-effort
                deleteAllEmbeddingsFiles()
            }
        } message: {
            Text("This deletes every saved voice fingerprint and per-meeting embedding cache. This cannot be undone.")
        }
    }

    private func deleteAllEmbeddingsFiles() {
        let root = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Meetings", isDirectory: true)
        guard let folders = try? FileManager.default.contentsOfDirectory(at: root,
            includingPropertiesForKeys: nil) else { return }
        for f in folders {
            let url = f.appendingPathComponent("embeddings.json")
            try? FileManager.default.removeItem(at: url)
        }
    }
}

private struct ManageIdentitiesView: View {
    @Environment(\.identityStore) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading) {
            Text("Stored Identities").font(.title2)
            if let store {
                List(store.identities) { identity in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(identity.displayName).font(.headline)
                            Text("\(identity.meetingCount) meetings · last seen \(relativeDate(identity.updatedAt))")
                                .font(.caption)
                                .foregroundColor(.textDim)
                        }
                        Spacer()
                        Button("Forget") { store.delete(id: identity.id) }
                            .foregroundColor(.recordRed)
                    }
                }
            }
            Button("Close") { dismiss() }
        }
        .padding()
        .frame(minWidth: 480, minHeight: 360)
    }

    private func relativeDate(_ d: Date) -> String {
        RelativeDateTimeFormatter().localizedString(for: d, relativeTo: Date())
    }
}
```

- [ ] **Step 3: Wire `IdentityMatchingSettingsSection()` into existing Settings scene**

หา settings root view แล้วเพิ่ม `IdentityMatchingSettingsSection()`

- [ ] **Step 4: Compile + commit**

```
xcodebuild -project Meeting.xcodeproj -scheme Meeting -destination 'platform=macOS' build
```

```bash
git add Meeting/App/SettingsScene.swift  # or whichever file
git commit -m "Settings — Identity Matching section (toggle + threshold + manage + reset)"
```

---

## Task 15: MenuBarLabel — embedding intermediate state

**Files:**
- Modify: `Meeting/App/MenuBarLabel.swift` (or AppState if state enum lives there)

- [ ] **Step 1: Add `embedding` to the state enum**

ที่ AppState (หรือ enum ที่ MenuBarLabel observe):

```swift
enum AppPipelineState {
    case idle
    case recording
    case transcribing
    case embedding   // NEW
    case done(success: Bool)
}
```

- [ ] **Step 2: Set state during embedding queue activity**

ใน `EmbeddingExtractionQueue.drain()` add callback:

```swift
actor EmbeddingExtractionQueue {
    var onStateChange: (@Sendable (_ active: Bool) -> Void)?
    // ...
    private func drain() async {
        onStateChange?(true)
        while let next = pending.first {
            // ...
        }
        onStateChange?(false)
        // ...
    }
}
```

ตอน wire ใน AppState:

```swift
embeddingQueue.onStateChange = { [weak self] active in
    Task { @MainActor in
        if active { self?.pipelineState = .embedding }
        else if self?.pipelineState == .embedding { self?.pipelineState = .done(success: true) }
    }
}
```

(หรือถ้า AppState ใช้ pattern อื่น ก็ adapt เหมือนกัน)

- [ ] **Step 3: Update MenuBarLabel ให้แสดง spinner เดียวกับ transcribing เมื่อ state == .embedding**

```swift
case .transcribing, .embedding:
    waveformSpinner()  // existing animation
```

- [ ] **Step 4: Compile + commit**

```bash
git add Meeting/App/MenuBarLabel.swift Meeting/App/AppState.swift \
        Meeting/Identity/EmbeddingExtractionQueue.swift
git commit -m "MenuBarLabel — show spinner during embedding extraction"
```

---

## Task 16: End-to-end manual test plan

**No code changes** — execute the manual test sequence with the running app + verify behavior

- [ ] **Test 1: First sighting creates identity**
  1. Record meeting `M1` กับเพื่อน 1 คน (ไม่แนบ calendar)
  2. รอ transcribe + embedding extraction เสร็จ (MenuBarLabel → done)
  3. เปิด Transcript Viewer
  4. หา `speaker_X` ที่เป็นเพื่อน → คลิก chip → พิมพ์ชื่อ "Test Subject" → Enter
  5. ดู `~/Library/Application Support/dev.fluke.meeting/identities.json` — ต้องมี 1 entry display name "Test Subject", `meetingCount: 1`

- [ ] **Test 2: Second meeting suggests**
  1. Record meeting `M2` กับคนเดิม → transcribe + embedding เสร็จ
  2. เปิด Transcript Viewer ของ M2
  3. ต้องเห็น suggestion chip ใต้ `speaker_N` ที่เป็นคนเดิม → confidence ≥ 70%
  4. คลิก ✓ → speaker เปลี่ยนเป็น "Test Subject" + chip หาย
  5. `identities.json` — entry เดิม `meetingCount: 2`, `seenIn` มี M2 อยู่บน

- [ ] **Test 3: Reject behavior**
  1. Record M3 กับคนเดิมอีก → ต้องเห็น suggestion
  2. คลิก ✗ → chip หาย, ใน `M3/embeddings.json.rejectedIdentities` เพิ่ม entry
  3. Quit + reopen app → Transcript Viewer ของ M3 → ไม่ suggest อีก
  4. แต่ Transcript Viewer ของ M4 (record ใหม่) → suggest กลับมา

- [ ] **Test 4: Reset all**
  1. Settings → Identity matching → Reset all → confirm
  2. `identities.json` หาย, ทุก `embeddings.json` หาย
  3. เปิด Library → Transcript Viewer ของแต่ละ meeting → ไม่มี suggestion + queue trigger ใหม่

- [ ] **Test 5: Monologue edge case**
  1. Record monologue 5 นาที (พูดคนเดียว)
  2. Transcribe + embedding extraction → ไม่ crash, `identities.json` ไม่เปลี่ยน (ยังไม่ได้ map "me" ดังนั้นไม่สร้าง identity)
  3. ตั้งชื่อ speaker_0 ใน Transcript Viewer → identity ถูกสร้าง

- [ ] **Test 6: Diarization phantom speakers**
  1. หา meeting ที่ diarize 5 speakers แต่จริงๆ 2 คน
  2. Embedding extraction → 5 entries ใน `embeddings.json`
  3. เปิด viewer → reject suggestion ที่ผิดทำได้ปกติ ไม่ crash

- [ ] **Test 7: Thai vs English vs code-switching**
  1. Record meeting ภาษาไทยล้วน → ตั้งชื่อ → identity สร้าง
  2. Record meeting คนเดิมพูด code-switching → ต้องยัง suggest ได้ confidence ≥ 60%

- [ ] **Step 8: ถ้าทุก test ผ่าน — ship**

```bash
git log --oneline -20  # quick history check
git push origin main   # if user requests
```

---

## Self-review (run inline after completing all tasks above)

**1. Spec coverage check:**
- ✅ V1 scope (auto-suggest only): Tasks 7, 9, 12, 13
- ✅ Pyannote v3 acoustic embedding: Tasks 5, 6
- ✅ Calendar / Meet name / recency priors: Task 7
- ✅ Identity store with running-mean centroid: Task 2
- ✅ Per-meeting embeddings cache + rejection log: Tasks 3, 9
- ✅ Mutual exclusion: Task 7
- ✅ Confidence percent UI: Task 7 (helper), Task 12 (display)
- ✅ Suggestion chip + top banner: Tasks 12, 13
- ✅ Settings (toggle + threshold + manage + reset): Task 14
- ✅ MenuBarLabel state: Task 15
- ✅ Error handling (silent fail to "no suggestion"): Task 8 (`embeddingFailed: true`), Task 6 (modelsAvailable gate)
- ✅ Backward compat (old speakers.json): Task 4
- ✅ Schema invalidation by embedderModel mismatch: Task 2

**2. Placeholder scan:** ทุก step มี code/command. ไม่มี TBD / TODO.

**3. Type consistency:**
- `Identity` defined Task 1, used Tasks 2, 7, 9, 10, 14
- `SpeakerEmbedding` defined Task 3, used Tasks 7, 9
- `Rejection` defined Task 3, used Tasks 7, 9
- `MatchContext`, `MatchingConfig`, `IdentitySuggestion` defined Task 7, used Tasks 9, 12
- `SpeakerEmbedder.modelTag` defined Task 6 (stub Task 2, replaced Task 6)
- `IdentityStore.create / updateCentroid / delete / reset / addEmail` defined Task 2, used Tasks 9, 14
- `MeetingsLibrary.applyIdentitySuggestion / rejectIdentitySuggestion / createOrReuseIdentity` defined Task 9, used Task 12

All consistent.
