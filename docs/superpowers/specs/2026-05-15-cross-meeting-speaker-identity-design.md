# Cross-meeting speaker identity — V1 design

**Status:** Approved 2026-05-15
**Scope:** Auto-suggest mapping ของ `speaker_N` ใน Transcript Viewer โดยใช้ acoustic embedding + calendar / Meet name priors

## Goal

ลด manual rename ของ `speaker_N` ในทุก meeting โดย:

1. รัน embedding ต่อ speaker ใน meeting ใหม่ (pyannote v3 Core ML — 192-dim)
2. Match กับ global identity store ผ่าน weighted score (cosine + calendar email + Meet name + recency)
3. ใน Transcript Viewer โชว์ suggestion chip — user คลิกยืนยันหรือปฏิเสธ
4. Confirm → apply mapping + update identity centroid (running mean) → meeting ครั้งหน้าฉลาดขึ้นเอง

## Non-goals (V1)

- "People" group ใน Library sidebar
- Bulk rename / propagate ย้อนหลังไปยัง meetings เก่า
- Merge / split / export identities
- Auto-rename โดยไม่ขอ user confirm
- Privacy-grade encryption ของ centroid (เก็บเป็น plain JSON ใน Application Support — Phase 2)

## Approach: Hybrid weighted scoring

### Lifecycle ของ identity

**ครั้งแรกที่ user ตั้งชื่อ speaker (manual mapping เดิม):**

1. User เปิด Transcript Viewer ของ meeting → ผูก `speaker_N` ↔ ชื่อ (ลาก attendee chip / พิมพ์)
2. ระบบ embed audio ของ `speaker_N` ผ่าน `SpeakerEmbedder` → 192-dim centroid
3. สร้าง `Identity` ใหม่ใน `~/Library/Application Support/dev.fluke.meeting/identities.json`

**Meeting ถัดไปที่คนเดิมโผล่:**

1. หลัง transcribe เสร็จ + Library scan: ระบบ embed ทุก `speaker_N` ใน meeting → เขียน `<meeting>/embeddings.json`
2. `IdentityMatcher` รัน scoring กับทุก identity ใน store → คืน top-3 candidates per speaker (above threshold)
3. Transcript Viewer โชว์ suggestion chip ใต้ speaker_N
4. User confirm → apply mapping + update identity centroid ด้วย running mean (weighted by `sampleSeconds`)

`meet_participants.json` (ชื่อจาก Google Meet UI) เป็น **boost เสริม** เท่านั้น — identity ถูกสร้างจากการที่ user **กดยืนยันชื่อ** ไม่ใช่จากการ scrape ชื่อ

## Architecture

### Layer ใหม่: `Meeting/Identity/`

| Component | Purpose |
|---|---|
| `SpeakerEmbedder` (`actor`) | Load argmax pyannote v3 Core ML model → embed audio → return 192-dim L2-normalized centroid |
| `IdentityStore` (`@MainActor ObservableObject`) | Read/write `identities.json`; APIs: append, update centroid, delete (forget), match query |
| `IdentityMatcher` | Compute scores per (speaker_N, identity) — pure function, no I/O |
| `MeetingEmbeddingsFile` (Codable) | On-disk cache ของ embeddings ต่อ meeting |

### Touch points กับโค้ดเก่า

| File | เปลี่ยนอะไร |
|---|---|
| `SpeakerMapFile.swift` | เพิ่ม optional field `identityID: String?` ใน `SpeakerProfile` |
| `MeetingRecord.swift` | เพิ่ม computed `identitySuggestions: [IdentitySuggestion]` (in-memory, ไม่ persist) |
| `MeetingsLibrary.swift` | `loadRecord()` เรียก `IdentityMatcher` หลังโหลด speakers + embeddings; เพิ่ม `applyIdentitySuggestion(...)` / `rejectIdentitySuggestion(...)` |
| `TranscriptionSession.swift` | เพิ่ม step "Extract embeddings" หลัง diarize (ผ่าน `EmbeddingExtractionQueue`) |
| `TranscriptViewerView.swift` | Suggestion chip ใต้ speaker_N + top banner เมื่อมี ≥2 suggestions |
| `AppPreferences.swift` | Threshold slider + identity store toggle + manage modal |
| `MenuBarLabel.swift` | เพิ่ม `embedding` intermediate state ระหว่าง transcribing → done |

### สิ่งที่ไม่แตะ

- `RecordingSession` — embedding ทำ post-record/transcribe, ไม่ใช่ระหว่าง capture
- `LocalProvider` — embedding step decoupled จาก transcription provider → cloud providers (Gemini, OpenAI) ใช้ feature นี้ได้

### Data flow

```
[Recording stop]
    ↓
TranscriptionSession.run() → transcript.json
    ↓
[NEW] EmbeddingExtractionQueue.enqueue(meeting)
    SpeakerEmbedder.embed() per speaker → embeddings.json
    ↓
Library scan loads MeetingRecord
    ↓
IdentityMatcher.match(embeddings.json, calendar.json, meet_participants.json, identities.json)
    → MeetingRecord.identitySuggestions (in-memory)
    ↓
TranscriptViewerView แสดง suggestion chip / banner
    ↓
User confirm → MeetingsLibrary.applyIdentitySuggestion()
    → speakers.json: set displayName + identityID
    → identities.json: running-mean centroid update + append seenIn
    → rescan
```

## Storage schema

### Global: `~/Library/Application Support/dev.fluke.meeting/identities.json`

```swift
struct IdentityStoreFile: Codable, Sendable {
    var schemaVersion: Int  // = 1
    var embedderModel: String  // "pyannote-v3-w8a16" — invalidation tag
    var identities: [Identity]
}

struct Identity: Codable, Hashable, Sendable, Identifiable {
    let id: String              // UUID string — stable
    var displayName: String
    var emails: [String]        // lowercased; alias-friendly
    var centroid: [Float]       // 192-dim L2-normalized
    var sampleSeconds: Double   // weight สำหรับ running mean
    var seenIn: [String]        // meeting folder names, sorted desc, capped 50
    var meetingCount: Int       // total (รวมที่ trim จาก seenIn ออกแล้ว)
    var createdAt: Date
    var updatedAt: Date
}
```

ขนาดบน disk: 100 identities × ~970 bytes ≈ 95 KB → trivial

### Per-meeting: `<meeting>/embeddings.json`

```swift
struct MeetingEmbeddingsFile: Codable, Sendable {
    var schemaVersion: Int  // = 1
    var embedderModel: String  // ตรงกับ identities.json — invalidate ถ้าไม่ตรง
    var embeddings: [SpeakerEmbedding]
    var rejectedIdentities: [Rejection]  // per-meeting "อย่า suggest X อีก"
    var embeddingFailed: Bool  // = true ถ้า extract throw — กัน retry loop
}

struct SpeakerEmbedding: Codable, Sendable {
    let speakerID: SpeakerID
    let centroid: [Float]       // 192-dim L2-normalized
    let sampleSeconds: Double
}

struct Rejection: Codable, Hashable, Sendable {
    let speakerID: SpeakerID
    let identityID: String
}
```

ขนาด: 5 speakers × ~800 bytes ≈ 4 KB ต่อ meeting

### Schema change: `<meeting>/speakers.json`

เพิ่ม optional field — meeting เก่า (ไม่มี field) decode เป็น `nil`:

```swift
struct SpeakerProfile: Codable, Hashable, Sendable {
    let id: SpeakerID
    var displayName: String
    var attendeeId: String?
    var email: String?
    var role: String?
    var identityID: String?  // ← NEW
}
```

### Atomic write + corruption recovery

ทุกไฟล์ใช้ `Data.write(to:options: .atomic)`. ถ้า `identities.json` parse fail → backup ไปที่ `identities.json.corrupt-<timestamp>` + start fresh empty store + log

## Embedding extraction

### Design: "Isolate-then-embed"

ตัด audio ของ speaker_N ออกมาก่อน → embed เสมือน mono-speaker recording (ไม่ replicate SpeakerKit's per-frame masking logic ใน sliding window):

```
1. Load mic.m4a + output.m4a เป็น 16 kHz mono [Float] (ผ่าน AudioProcessor.loadAudioAsFloatArray)
2. For each speakerID ใน transcript:
   a. รวบ segments ของ speaker นั้น
   b. ตัด overlap (ช่วงที่ speaker อื่นพูดทับ) + boundary ±200ms
   c. Concatenate slices
   d. ถ้า total duration < 3s → skip (ยังไม่พอตัวอย่าง)
3. Chunk เป็น 5s window + overlap 0.5s
4. Per chunk:
   - SpeakerEmbedderPreprocessor (waveform → features)
   - SpeakerEmbedder (speakerMasks = ones, features → 192-dim embedding)
   - L2 normalize
5. Average chunk embeddings → centroid
6. L2 normalize centroid
```

**Trade-off:** แม่นยำน้อยลงเล็กน้อยเทียบกับ SpeakerKit's full pipeline (sliding window + activity mask) แต่ decoupled จาก SpeakerKit internals → ทน upstream change ได้ + เพียงพอสำหรับ "suggest" use case

### Core ML model paths

```
<ModelStorage.downloadBase()>/models/argmaxinc/speakerkit-coreml/speaker_embedder/pyannote-v3/W8A16/SpeakerEmbedderPreprocessor.mlmodelc
<ModelStorage.downloadBase()>/models/argmaxinc/speakerkit-coreml/speaker_embedder/pyannote-v3/W8A16/SpeakerEmbedder.mlmodelc
```

`SpeakerEmbedder.ensureModelsAvailable()` เรียก `LocalProvider.loadDiarizer()` เพื่อ trigger SpeakerKit ดาวน์โหลด weights ถ้ายังไม่มี — ครั้งแรกใช้เวลา ~30 วินาที

ถ้าผู้ใช้ไม่เคย transcribe แบบ Local เลย → ไฟล์ไม่มี → Settings โชว์ "ต้อง transcribe ด้วย Local Provider ก่อน 1 ครั้ง" + disable suggestion toggle

### `SpeakerEmbedder` skeleton

```swift
actor SpeakerEmbedder {
    static let modelTag = "pyannote-v3-w8a16"

    private var preEmbedder: MLModel?
    private var embedder: MLModel?
    private var loadTask: Task<Void, Error>?

    func ensureModelsAvailable() async throws  // delegates to LocalProvider's diarizer load
    func loadModels() async throws             // single-flight (เหมือน LocalProvider pattern)
    func embed(audioSegments: [[Float]]) async throws -> [Float]?  // returns nil ถ้า < 3s
    func unloadModels() async                  // หลัง batch ของ meeting เสร็จ
}
```

Memory budget: preEmbedder + embedder ≈ 30 MB (W8A16). Load on demand, unload after meeting batch

### When does embedding run?

`MeetingsLibrary.loadRecord()` ตรวจ — ถ้ามี transcript แต่ไม่มี `embeddings.json` → enqueue ใน `EmbeddingExtractionQueue` (peer ของ `TranscriptionQueue`, serial, 1-at-a-time, async)

**ไม่รันใน `TranscriptionSession.run()`** เพราะ:
- ไม่ block transcript display
- Idempotent — ลบ embeddings.json ทิ้ง → regenerate ครั้งหน้า
- Cloud-transcribed meetings (Gemini/OpenAI) ใช้ feature ได้เหมือนกัน

### Critical assumption ที่ต้อง verify

Output shape ของ pyannote-v3 embedder = 192. Integration test (`SpeakerEmbedderIntegrationTests.testOutputShape`) ตรวจครั้งแรกก่อน schema commit — ถ้า argmax bump เป็น 256 ใน Pro tier → test fail → catch ทัน

## Matching algorithm

### Score formula

```
score(speaker_N, identity_X) = 0.65 * embeddingScore
                             + 0.20 * calendarPrior
                             + 0.10 * meetNamePrior
                             + 0.05 * recencyPrior
```

| Term | คำนวณ |
|---|---|
| `embeddingScore` | `max(0, cosineSimilarity(speaker_N.centroid, identity_X.centroid))` — ใช้ vDSP_dotpr (L2-normalized แล้ว) |
| `calendarPrior` | `1.0` ถ้า `identity_X.emails ∩ meeting.attendeeEmails ≠ ∅` else `0.0` |
| `meetNamePrior` | `1.0` exact match (case-insensitive trim) ใน `meet_participants.json`; `0.7` ถ้า `1 - levenshteinDistance(a, b) / max(a.count, b.count) >= 0.85`; else `0.0` |
| `recencyPrior` | `exp(-daysSinceLastSeen / 30)` clamp [0, 1] |

### Threshold + ranking config

```swift
struct MatchingConfig {
    var minSuggestScore: Double = 0.55      // ต่ำกว่า → ไม่ suggest
    var highConfidenceScore: Double = 0.75   // สูงกว่า → UI "very likely"
    var maxSuggestionsPerSpeaker: Int = 3
}
```

User ปรับ `minSuggestScore` ผ่าน Settings slider:
- Conservative = 0.70
- Middle = 0.55 (default)
- Aggressive = 0.45

### Mutual exclusion (one identity per meeting)

ไม่ suggest Identity X ให้ทั้ง speaker_0 และ speaker_1 — greedy assignment หลังคำนวณ score matrix:

1. คำนวณ score ทุกคู่ (speaker, identity)
2. ดึงคู่ score สูงสุด → ถ้าทั้ง 2 ตัวยังไม่ claim → claim
3. Repeat จนหมด pair > threshold

Hungarian-lite — 5-10 speakers × 50 identities, greedy ใกล้ optimal และง่ายต่อ test

### Confidence display

```swift
func confidencePercent(_ score: Double) -> Int {
    let normalized = (score - 0.55) / (1.0 - 0.55)
    return Int(50 + normalized * 49)  // 0.55 → 50%, 1.0 → 99%
}
```

ไม่ใช้ raw cosine % — user จะตีความผิดว่าเป็น probability

### Update centroid on confirm

```swift
func confirm(speaker_N: SpeakerEmbedding, identity: Identity) -> Identity {
    let w_old = identity.sampleSeconds
    let w_new = speaker_N.sampleSeconds
    let total = w_old + w_new
    var c = [Float](repeating: 0, count: identity.centroid.count)
    for i in 0..<c.count {
        c[i] = Float((Double(identity.centroid[i]) * w_old
                    + Double(speaker_N.centroid[i]) * w_new) / total)
    }
    return Identity(
        ...identity,
        centroid: l2Normalize(c),  // weighted-avg ของ unit vectors ≠ unit
        sampleSeconds: total,
        seenIn: Array(([meetingID] + identity.seenIn).prefix(50)),
        meetingCount: identity.meetingCount + 1,
        updatedAt: Date()
    )
}
```

### Edge cases

| Case | Behavior |
|---|---|
| Identity ผูกกับ "me" (mic stream) | Skip — `me` ไม่ผ่าน diarization, ไม่ต้อง suggest |
| speaker_N มี displayName ที่ user เคยพิมพ์แล้ว (ไม่ใช่ "speaker_N") | Skip — user ตั้งใจ ไม่ override |
| meeting ไม่มี calendar.json | calendarPrior = 0 ทุกตัว — graceful degrade |
| meeting ไม่มี meet_participants.json | meetNamePrior = 0 ทุกตัว |
| identity เพิ่งสร้าง (seenIn 1) | คำนวณปกติ — confidence จะต่ำกว่า identity ที่ผ่านการ confirm หลายครั้งโดยธรรมชาติ |

## UI changes

### Transcript Viewer: Suggestion chip

ในแต่ละ speaker_N ที่ยังไม่ถูกผูก:

```
● speaker_0
  suggested: Sun Sarin · 83%        ✓  ✗
```

- คลิก chip body → Menu แสดง top-3 candidates
- ✓ confirm → apply + update centroid + clear suggestion
- ✗ reject → append `Rejection` ลง `embeddings.json.rejectedIdentities` → suggestion #2 ขึ้นแทน

### Transcript Viewer: Top banner

โผล่เมื่อมี ≥2 suggestions ค้างใน meeting:

```
💡 3 suggestions พบจาก meeting อื่น  [ดู] [ปิด]
```

- "ดู" → scroll + highlight Speakers card
- "ปิด" = dismiss session — เปิด viewer ใหม่จะโผล่อีก (ไม่ persist)

**ไม่มี "Confirm all"** — user ควรเช็คทีละคน, mis-confirm = pollute centroid ทั่ว store

### Settings: Identity matching section

```
Identity matching
  ☑ Suggest speakers from past meetings
  Suggestion threshold:  [Conservative ─●─ Aggressive]

  Stored identities: 12  [Manage…]   [Reset all…]
```

- `[Manage…]` → modal: list identities + displayName + meetingCount + last seen — delete ทีละคน ("forget person")
- `[Reset all…]` → ลบ `identities.json` + `embeddings.json` ของทุก meeting (confirm 2 ชั้น)

### MenuBarLabel state machine

```
idle → recording → transcribing → [NEW] embedding → done
```

- Embedding ใช้เวลา ~5-15s ต่อ meeting (~5 speakers × inference)
- Animation เหมือน transcribing — ไม่แยก spinner
- Embed fail → ข้ามไปยัง done (silent — log warning)

### Library

ไม่มี UI change ใน V1 — ไม่เพิ่ม "People" group

## Error handling

| Failure | UI |
|---|---|
| Model files หาย (ผู้ใช้ยังไม่เคย transcribe local) | Settings: "ต้อง transcribe ด้วย Local Provider ก่อนอย่างน้อย 1 ครั้ง" + disable toggle |
| Embedding fail (corrupt audio) | Silent — set `embeddingFailed: true` ใน embeddings.json + log |
| Identity store corrupt JSON | Backup ไป `identities.json.corrupt-<timestamp>` + start fresh + log |
| Embedding shape mismatch (v3 → v4) | Throw `EmbedderShapeMismatch` → disable feature + Settings โชว์ "ต้อง update" |
| Speaker audio < 3s | Skip — suggestion ของ speaker นั้น empty |

หลักการ: silent fail → "ไม่มี suggestion" ไม่เคย block transcript เปิด/อ่าน

## Testing

### Unit tests

- `IdentityMatcherTests` — score formula, weight blending, threshold cutoff, mutual exclusion
- `IdentityStoreTests` — read/write roundtrip, running-mean centroid update, schemaVersion mismatch
- `MeetingEmbeddingsFileTests` — read/write, rejection append
- `SpeakerEmbedderTests` — concat + chunking + L2 norm helpers (no Core ML)
- `IdentityConfidenceTests` — score → percent mapping

### Integration tests

- `SpeakerEmbedderIntegrationTests` — load Core ML จริง → embed 5s test audio → verify shape 192, L2 norm = 1.0 ± 0.01
- `EndToEndSuggestionFlowTests` — fake transcript + identities → matcher → verify suggested mapping + confirmed centroid update

### Fixtures

- `MeetingTests/fixtures/two-speaker-5s.wav` — short audio 2-speaker เพื่อ verify embedder output shape (catch ถ้า argmax bump dim)

### Manual test plan

1. Record meeting #1 กับเพื่อน 1 คน (ไม่มี calendar) → ผูกชื่อ → verify identity ถูกสร้าง
2. Record meeting #2 คนเดิม → verify suggestion confidence ≥70%
3. Reject suggestion → verify ไม่ suggest อีกใน meeting นั้น แต่ meeting อื่นยัง
4. Reset all → verify identities.json + ทุก embeddings.json หาย
5. Edge: monologue (1 speaker) → verify embedder ไม่ crash + identity ถูกสร้าง
6. Edge: diarization เพี้ยน (5 speakers แต่จริงๆ 2) → verify ไม่ crash + reject ผิดได้
7. Edge: meeting ภาษาไทยล้วน vs โซนคนละภาษา → embedder ทำงานได้เท่ากัน

## Rollout

V1 release with feature **on by default** หลัง:
- ✅ Unit + integration tests pass
- ✅ Manual test 7 cases ผ่าน
- ✅ Verified บน meeting ไทย + อังกฤษ + code-switching

Settings toggle ให้ user **ปิด** ได้สำหรับ privacy-conscious users

## Open questions / risks

- **Argmax bump pyannote v3 → v4 ใน next SpeakerKit release** — output dim หรือ semantic เปลี่ยน → schema invalidate. Mitigation: integration test ตรวจ shape ทุก build + `embedderModel` tag ใน identities.json เป็นกุญแจ migrate
- **Speaker ที่เสียงคล้ายมากๆ (พี่น้องคนละคน)** — centroid distance อาจ < threshold เสมอ → user reject ซ้ำๆ. Mitigation: per-meeting rejection แก้กรณี false-positive ใน meeting เดียว แต่ระยะยาวต้อง user merge/split manually (Phase 2)
- **Lazy backfill ของ meeting เก่า** — meeting หลายร้อยตัว เปิด Library ครั้งแรกจะคิว embedding extraction เยอะ. Mitigation: `EmbeddingExtractionQueue` serial + low priority + cap concurrent jobs ที่ 1

## References

- Roadmap entry: `docs/roadmap.md` § "Cross-meeting speaker identity"
- SpeakerKit source (เป็น blueprint สำหรับ preprocessing): `~/Library/Developer/Xcode/DerivedData/Meeting-*/SourcePackages/checkouts/WhisperKit/Sources/SpeakerKit/Pyannote/SpeakerEmbedderModel.swift`
- Model artifacts: `~/Library/Application Support/dev.fluke.meeting/Models/models/argmaxinc/speakerkit-coreml/speaker_embedder/pyannote-v3/W8A16/`
