import Foundation
import Combine
import AppKit

/// User-configurable knobs that persist across launches via UserDefaults.
/// One central source of truth for everything Settings exposes.
@MainActor
final class AppPreferences: ObservableObject {
    static let shared = AppPreferences()

    /// Stable device UID picked in Settings → Recording or the menu-bar
    /// popover chip. `nil` = follow the system default input device.
    /// Persisted as String?; `MicRecorder` applies it when starting the
    /// audio engine.
    @Published var micDeviceUID: String? {
        didSet { UserDefaults.standard.set(micDeviceUID, forKey: Keys.micDeviceUID) }
    }

    @Published var modelVariant: ModelVariant {
        didSet { UserDefaults.standard.set(modelVariant.rawValue, forKey: Keys.modelVariant) }
    }

    @Published var transcriptionLanguage: TranscriptionLanguage {
        didSet { UserDefaults.standard.set(transcriptionLanguage.rawValue, forKey: Keys.transcriptionLanguage) }
    }

    /// Which transcription engine drives `TranscriptionSession`. `.local`
    /// is the default (WhisperKit + SpeakerKit, fully offline). Cloud
    /// engines call out to provider APIs for the text and still rely on
    /// local SpeakerKit for diarization.
    @Published var transcriptionEngine: TranscriptionEngine {
        didSet { UserDefaults.standard.set(transcriptionEngine.rawValue, forKey: Keys.transcriptionEngine) }
    }

    /// Comma-separated glossary of domain / tech vocabulary primed into the
    /// cloud provider's system instruction so terms like "Kubernetes",
    /// "gRPC", "MR" survive Thai-English code-switching. Ignored by the
    /// local WhisperKit provider (it doesn't accept prompt context).
    @Published var transcriptionGlossary: String {
        didSet { UserDefaults.standard.set(transcriptionGlossary, forKey: Keys.transcriptionGlossary) }
    }

    /// Gemini API key (plaintext in UserDefaults — TODO migrate to Keychain).
    /// Empty string = not configured; `GeminiProvider` throws a clear error
    /// pointing the user to Settings.
    @Published var geminiAPIKey: String {
        didSet { UserDefaults.standard.set(geminiAPIKey, forKey: Keys.geminiAPIKey) }
    }

    /// Which Gemini model to call. `flash` is the default — fast and cheap —
    /// but Google's free tier pools occasionally show 503 UNAVAILABLE under
    /// load; `pro` runs on a separate pool and is a useful escape hatch.
    @Published var geminiModel: GeminiModel {
        didSet { UserDefaults.standard.set(geminiModel.rawValue, forKey: Keys.geminiModel) }
    }

    /// Submit chunks via Gemini's Batch API instead of synchronous
    /// `generateContent` calls. Halves token cost (Google charges 50% for
    /// batch) at the cost of latency — batches usually complete in a few
    /// minutes but the SLA is 24 h, and the app must stay open until the
    /// poll loop sees `BATCH_STATE_SUCCEEDED`. Off by default so existing
    /// users see no behavior change.
    @Published var geminiUseBatchAPI: Bool {
        didSet { UserDefaults.standard.set(geminiUseBatchAPI, forKey: Keys.geminiUseBatchAPI) }
    }

    /// OpenAI API key (plaintext in UserDefaults — TODO Keychain).
    @Published var openaiAPIKey: String {
        didSet { UserDefaults.standard.set(openaiAPIKey, forKey: Keys.openaiAPIKey) }
    }

    /// Which OpenAI transcription model. Defaults to `gpt-4o-transcribe`
    /// — the newest and highest-quality option, though it may not return
    /// segment-level timestamps in `verbose_json`. `whisper-1` is the
    /// classic choice if accurate per-segment timestamps matter (it's the
    /// same Whisper architecture as our local provider, just hosted).
    @Published var openaiModel: OpenAIModel {
        didSet { UserDefaults.standard.set(openaiModel.rawValue, forKey: Keys.openaiModel) }
    }

    @Published var showMenuBarTimer: Bool {
        didSet { UserDefaults.standard.set(showMenuBarTimer, forKey: Keys.showMenuBarTimer) }
    }

    @Published var appearance: AppearancePreference {
        didSet {
            UserDefaults.standard.set(appearance.rawValue, forKey: Keys.appearance)
            appearance.apply()
        }
    }

    /// Email addresses the user owns. Used to mark calendar attendees as
    /// `isMe` so the speaker-mapping chips skip the user themselves.
    /// Stored as a comma-separated string in UserDefaults; always lowercased.
    @Published var myEmails: Set<String> {
        didSet {
            UserDefaults.standard.set(
                myEmails.sorted().joined(separator: ","),
                forKey: Keys.myEmails
            )
        }
    }

    /// Manual override for group emails that EventKit can't expand into
    /// individual members (Google Workspace groups, distribution lists,
    /// etc.). Maps lowercased group email → list of members.
    /// `CalendarStore.snapshot` substitutes the group entry with these
    /// members when building `calendar.json`, so the Library detail and
    /// the LLM prompt see real people instead of a single "group" line.
    /// Stored as JSON in UserDefaults.
    @Published var groupExpansions: [String: [GroupMember]] {
        didSet {
            let data = try? JSONEncoder().encode(groupExpansions)
            UserDefaults.standard.set(data, forKey: Keys.groupExpansions)
        }
    }

    /// Destination folder where `Generate Note` writes the per-meeting
    /// Markdown file (designed for an Obsidian vault). Stored as the
    /// path string; resolved to URL at write time. Empty string falls
    /// back to `~/Documents/Obsidian/Fluke/meeting-notes/` so a fresh
    /// install lands in a sensible place without first opening Settings.
    @Published var meetingNotesFolder: String {
        didSet { UserDefaults.standard.set(meetingNotesFolder, forKey: Keys.meetingNotesFolder) }
    }

    /// Root folder where `RecordingSession` saves each meeting's
    /// timestamped subfolder, and that `MeetingsLibrary` watches /
    /// indexes. Stored as the path string. Empty string falls back to
    /// `~/Documents/Meetings/` (the long-standing default) so the first
    /// launch works without opening Settings.
    @Published var meetingsFolder: String {
        didSet { UserDefaults.standard.set(meetingsFolder, forKey: Keys.meetingsFolder) }
    }

    /// Whether the cross-meeting speaker identity matcher runs at all. When
    /// off, MeetingsLibrary is constructed without an IdentityStore reference
    /// so no suggestions surface and no new identities accumulate.
    @Published var identitySuggestionsEnabled: Bool {
        didSet { UserDefaults.standard.set(identitySuggestionsEnabled, forKey: Keys.identitySuggestionsEnabled) }
    }

    /// Matcher threshold — scores below this are dropped before the UI sees
    /// them. Settings exposes 0.45 (aggressive) … 0.70 (conservative) in
    /// 0.05 steps.
    @Published var identityMinSuggestScore: Double {
        didSet { UserDefaults.standard.set(identityMinSuggestScore, forKey: Keys.identityMinSuggestScore) }
    }

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

    /// Master toggle for the auto-record feature. Off by default — users
    /// have to opt in. When off, the scheduler stays idle even if other
    /// settings are populated.
    @Published var autoRecordEnabled: Bool {
        didSet { UserDefaults.standard.set(autoRecordEnabled, forKey: Keys.autoRecordEnabled) }
    }

    /// Countdown duration in seconds shown before recording starts. UI
    /// constrains to {3, 5, 10, 30}; out-of-range values get clamped.
    @Published var autoRecordCountdownSeconds: Int {
        didSet { UserDefaults.standard.set(autoRecordCountdownSeconds, forKey: Keys.autoRecordCountdownSeconds) }
    }

    /// EventKit calendar identifiers the user explicitly opted in to.
    /// Stored as a comma-separated string in UserDefaults. Empty set +
    /// `autoRecordEnabled == true` is a valid state (scheduler stays idle,
    /// Settings shows a "pick at least one calendar" nudge).
    @Published var autoRecordEnabledCalendarIDs: Set<String> {
        didSet {
            UserDefaults.standard.set(
                autoRecordEnabledCalendarIDs.sorted().joined(separator: ","),
                forKey: Keys.autoRecordEnabledCalendarIDs
            )
        }
    }

    /// Behavior when source resolution finds no matching window.
    @Published var autoRecordSourceFallback: AutoRecordSourceFallback {
        didSet { UserDefaults.standard.set(autoRecordSourceFallback.rawValue, forKey: Keys.autoRecordSourceFallback) }
    }

    /// How long the library keeps each meeting's `video.mov` before
    /// auto-trashing it to reclaim disk space. Audio, transcript, marks,
    /// and every other artifact are always kept — only the (large) video
    /// file is removed. `.keepForever` (default) disables the sweep so
    /// existing users see no change; starred meetings are always exempt.
    @Published var videoRetention: VideoRetention {
        didSet { UserDefaults.standard.set(videoRetention.rawValue, forKey: Keys.videoRetention) }
    }

    /// Master toggle for system-wide voice dictation (double-tap Ctrl to
    /// dictate into the frontmost app). Off by default - the feature needs
    /// the Accessibility TCC grant, so users opt in explicitly. When on but
    /// Accessibility is missing, the hotkey monitor simply never starts.
    @Published var dictationEnabled: Bool {
        didSet { UserDefaults.standard.set(dictationEnabled, forKey: Keys.dictationEnabled) }
    }

    /// Which backend transcribes a dictation utterance. Independent of the
    /// meeting `transcriptionEngine`. Defaults to Gemini 2.5 Pro (highest
    /// quality on Thai-English); falls back to local automatically when no
    /// Gemini key is configured.
    @Published var dictationEngine: DictationEngine {
        didSet { UserDefaults.standard.set(dictationEngine.rawValue, forKey: Keys.dictationEngine) }
    }

    /// Forced language for dictation transcription. Defaults to Thai (same
    /// as meetings) so Thai-English code-switching keeps Thai script.
    @Published var dictationLanguage: TranscriptionLanguage {
        didSet { UserDefaults.standard.set(dictationLanguage.rawValue, forKey: Keys.dictationLanguage) }
    }

    private init() {
        self.micDeviceUID = UserDefaults.standard.string(forKey: Keys.micDeviceUID)
        self.modelVariant = ModelVariant(
            rawValue: UserDefaults.standard.string(forKey: Keys.modelVariant) ?? ""
        ) ?? .largeV3
        self.transcriptionLanguage = TranscriptionLanguage(
            rawValue: UserDefaults.standard.string(forKey: Keys.transcriptionLanguage) ?? ""
        ) ?? .thai
        self.transcriptionEngine = TranscriptionEngine(
            rawValue: UserDefaults.standard.string(forKey: Keys.transcriptionEngine) ?? ""
        ) ?? .local
        self.transcriptionGlossary = UserDefaults.standard.string(forKey: Keys.transcriptionGlossary)
            ?? TranscriptionEngine.defaultGlossary
        self.geminiAPIKey = UserDefaults.standard.string(forKey: Keys.geminiAPIKey) ?? ""
        self.geminiModel = GeminiModel(
            rawValue: UserDefaults.standard.string(forKey: Keys.geminiModel) ?? ""
        ) ?? .pro
        self.geminiUseBatchAPI = UserDefaults.standard.bool(forKey: Keys.geminiUseBatchAPI)
        self.openaiAPIKey = UserDefaults.standard.string(forKey: Keys.openaiAPIKey) ?? ""
        self.openaiModel = OpenAIModel(
            rawValue: UserDefaults.standard.string(forKey: Keys.openaiModel) ?? ""
        ) ?? .gpt4oTranscribe
        // Default the menu-bar timer to ON so existing users see no change.
        self.showMenuBarTimer = (UserDefaults.standard.object(forKey: Keys.showMenuBarTimer) as? Bool) ?? true
        self.appearance = AppearancePreference(
            rawValue: UserDefaults.standard.string(forKey: Keys.appearance) ?? ""
        ) ?? .system
        let rawEmails = UserDefaults.standard.string(forKey: Keys.myEmails) ?? ""
        self.myEmails = Set(
            rawEmails.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                .filter { !$0.isEmpty }
        )
        if let data = UserDefaults.standard.data(forKey: Keys.groupExpansions),
           let decoded = try? JSONDecoder().decode([String: [GroupMember]].self, from: data) {
            self.groupExpansions = decoded
        } else {
            self.groupExpansions = [:]
        }
        let storedNotesFolder = UserDefaults.standard.string(forKey: Keys.meetingNotesFolder) ?? ""
        self.meetingNotesFolder = storedNotesFolder.isEmpty
            ? Self.defaultMeetingNotesFolder
            : storedNotesFolder
        let storedMeetingsFolder = UserDefaults.standard.string(forKey: Keys.meetingsFolder) ?? ""
        self.meetingsFolder = storedMeetingsFolder.isEmpty
            ? Self.defaultMeetingsFolder
            : storedMeetingsFolder
        // Identity matching defaults to ON so new installs get suggestions
        // without first visiting Settings.
        self.identitySuggestionsEnabled = (UserDefaults.standard.object(forKey: Keys.identitySuggestionsEnabled) as? Bool) ?? true
        let storedMin = UserDefaults.standard.object(forKey: Keys.identityMinSuggestScore) as? Double
        self.identityMinSuggestScore = storedMin ?? 0.45
        self.autoNameSpeakersEnabled = (UserDefaults.standard.object(forKey: Keys.autoNameSpeakersEnabled) as? Bool) ?? true
        let storedAutoThreshold = UserDefaults.standard.object(forKey: Keys.autoNameThreshold) as? Double
        self.autoNameThreshold = storedAutoThreshold ?? 0.80
        self.autoRecordEnabled = UserDefaults.standard.bool(forKey: Keys.autoRecordEnabled)
        let storedCountdown = UserDefaults.standard.integer(forKey: Keys.autoRecordCountdownSeconds)
        let allowed: Set<Int> = [3, 5, 10, 30]
        self.autoRecordCountdownSeconds = allowed.contains(storedCountdown) ? storedCountdown : 5
        let rawCalIDs = UserDefaults.standard.string(forKey: Keys.autoRecordEnabledCalendarIDs) ?? ""
        self.autoRecordEnabledCalendarIDs = Set(
            rawCalIDs.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        )
        self.autoRecordSourceFallback = AutoRecordSourceFallback(
            rawValue: UserDefaults.standard.string(forKey: Keys.autoRecordSourceFallback) ?? ""
        ) ?? .display
        self.videoRetention = VideoRetention(
            rawValue: UserDefaults.standard.string(forKey: Keys.videoRetention) ?? ""
        ) ?? .keepForever
        self.dictationEnabled = UserDefaults.standard.bool(forKey: Keys.dictationEnabled)
        self.dictationEngine = DictationEngine(
            rawValue: UserDefaults.standard.string(forKey: Keys.dictationEngine) ?? ""
        ) ?? .gemini
        self.dictationLanguage = TranscriptionLanguage(
            rawValue: UserDefaults.standard.string(forKey: Keys.dictationLanguage) ?? ""
        ) ?? .thai
        // Don't call `appearance.apply()` here: AppPreferences.shared is
        // first touched during MeetingApp.init / AppState.init, which
        // runs *before* NSApplication is fully online — `NSApp` is still
        // nil and dereferencing it traps. The initial apply happens in
        // AppDelegate.applicationDidFinishLaunching once NSApp exists.
        // Subsequent changes go through `appearance.didSet` and apply
        // immediately because by then NSApp is up.
    }

    /// Apply every preference that touches AppKit globals. Call exactly
    /// once from AppDelegate after NSApplication is fully initialized;
    /// any later changes route through `didSet` on the individual prefs.
    func applyAppKitSideEffects() {
        appearance.apply()
    }

    /// Default Obsidian vault path for meeting notes, used when the
    /// stored value is empty. Tilde-expanded so `~/Documents/...` works
    /// regardless of the running user.
    static let defaultMeetingNotesFolder =
        ("~/Documents/Obsidian/Fluke/meeting-notes" as NSString).expandingTildeInPath

    /// Default root folder for recordings — the historical
    /// `~/Documents/Meetings/` path. Used when the stored value is
    /// empty so existing installs keep their library exactly where
    /// they expect it.
    static let defaultMeetingsFolder =
        ("~/Documents/Meetings" as NSString).expandingTildeInPath

    /// `meetingsFolder` resolved to a URL with directory semantics —
    /// what callers actually need.
    var meetingsFolderURL: URL {
        URL(fileURLWithPath: meetingsFolder, isDirectory: true)
    }

    private enum Keys {
        static let micDeviceUID = "dev.fluke.meeting.micDeviceUID"
        static let modelVariant = "dev.fluke.meeting.modelVariant"
        static let transcriptionLanguage = "dev.fluke.meeting.transcriptionLanguage"
        static let transcriptionEngine = "dev.fluke.meeting.transcriptionEngine"
        static let transcriptionGlossary = "dev.fluke.meeting.transcriptionGlossary"
        static let geminiAPIKey = "dev.fluke.meeting.geminiAPIKey"
        static let geminiModel = "dev.fluke.meeting.geminiModel"
        static let geminiUseBatchAPI = "dev.fluke.meeting.geminiUseBatchAPI"
        static let openaiAPIKey = "dev.fluke.meeting.openaiAPIKey"
        static let openaiModel = "dev.fluke.meeting.openaiModel"
        static let showMenuBarTimer = "dev.fluke.meeting.showMenuBarTimer"
        static let appearance = "dev.fluke.meeting.appearance"
        static let myEmails = "dev.fluke.meeting.myEmails"
        static let groupExpansions = "dev.fluke.meeting.groupExpansions"
        static let meetingNotesFolder = "dev.fluke.meeting.meetingNotesFolder"
        static let meetingsFolder = "dev.fluke.meeting.meetingsFolder"
        static let identitySuggestionsEnabled = "dev.fluke.meeting.identitySuggestionsEnabled"
        static let identityMinSuggestScore = "dev.fluke.meeting.identityMinSuggestScore"
        static let autoNameSpeakersEnabled = "dev.fluke.meeting.autoNameSpeakersEnabled"
        static let autoNameThreshold = "dev.fluke.meeting.autoNameThreshold"
        static let autoRecordEnabled = "dev.fluke.meeting.autoRecordEnabled"
        static let autoRecordCountdownSeconds = "dev.fluke.meeting.autoRecordCountdownSeconds"
        static let autoRecordEnabledCalendarIDs = "dev.fluke.meeting.autoRecordEnabledCalendarIDs"
        static let autoRecordSourceFallback = "dev.fluke.meeting.autoRecordSourceFallback"
        static let videoRetention = "dev.fluke.meeting.videoRetention"
        static let dictationEnabled = "dev.fluke.meeting.dictationEnabled"
        static let dictationEngine = "dev.fluke.meeting.dictationEngine"
        static let dictationLanguage = "dev.fluke.meeting.dictationLanguage"
    }
}

// MARK: - Group expansion

/// Single member of a manually-expanded calendar group. Email is required
/// (so we can dedupe / mark `isMe`); display name is optional and falls
/// back to the email's local part in the UI.
struct GroupMember: Codable, Hashable, Sendable, Identifiable {
    var id: String { email.lowercased() }
    let name: String?
    let email: String

    init(name: String? = nil, email: String) {
        self.name = name?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        self.email = email.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// Display name resolved against the optional `name` field — falls
    /// back to the email's local part ("foo@bar.com" → "foo") so empty
    /// chips never appear.
    var displayName: String {
        if let name { return name }
        return email.components(separatedBy: "@").first ?? email
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Whisper model variant

/// Whisper model size + quantization. Larger = more accurate but slower.
/// `large-v3-turbo` is ~4× faster than `large-v3` but its language detection
/// has been observed to misclassify Thai as English when set to auto.
enum ModelVariant: String, CaseIterable, Identifiable, Sendable {
    case largeV3 = "large-v3"
    case largeV3Turbo = "large-v3-turbo"
    /// Thai-fine-tuned Whisper Large v3 from biodatlab (Mahidol). Same
    /// architecture as OpenAI's whisper-large-v3 (32-layer decoder, full
    /// attention), only the weights are fine-tuned — so whisperkittools
    /// converts it cleanly. Not on argmaxinc/whisperkit-coreml: run
    /// `tools/biodatlab-whisper-th/setup.sh` once to convert it locally;
    /// `LocalProvider` then loads it from Application Support.
    ///
    /// We tried `biodatlab/distill-whisper-th-large-v3` first, but the
    /// distilled architecture (2-layer decoder + custom token head) is
    /// not handled correctly by whisperkittools' generic conversion path
    /// — it produced plausible-but-meaningless Thai. The non-distilled
    /// variant here is the working alternative.
    case biodatlabThLargeV3 = "biodatlab-whisper-th-large-v3"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .largeV3: "Large v3 (accurate)"
        case .largeV3Turbo: "Large v3 Turbo (fast)"
        case .biodatlabThLargeV3: "Whisper TH Large v3 (Thai-tuned)"
        }
    }

    var description: String {
        switch self {
        case .largeV3: "Best for Thai / multilingual content. ~3-5× real-time."
        case .largeV3Turbo: "~10-15× real-time. Risk of mis-detecting Thai as English when language is Auto."
        case .biodatlabThLargeV3: "biodatlab Thai fine-tune. Run tools/biodatlab-whisper-th/setup.sh once before selecting."
        }
    }

    /// Returns the local model folder if this variant ships outside the
    /// argmaxinc HF repo. `nil` for stock variants → WhisperKit downloads
    /// from `argmaxinc/whisperkit-coreml` as usual.
    var customModelFolder: URL? {
        switch self {
        case .largeV3, .largeV3Turbo:
            return nil
        case .biodatlabThLargeV3:
            return URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support/dev.fluke.meeting/Models/custom/biodatlab-whisper-th-large-v3")
        }
    }
}

// MARK: - Transcription language

/// Forced language for Whisper. `.auto` lets Whisper detect — works on
/// most languages but unreliable for Thai/CJK on the turbo variant.
enum TranscriptionLanguage: String, CaseIterable, Identifiable, Sendable {
    case auto
    case thai = "th"
    case english = "en"
    case japanese = "ja"
    case chinese = "zh"

    var id: String { rawValue }

    /// Value to feed to `TranscriptionOptions.language`. `nil` = Whisper auto.
    var whisperCode: String? {
        self == .auto ? nil : rawValue
    }

    var displayName: String {
        switch self {
        case .auto: "Auto detect"
        case .thai: "Thai"
        case .english: "English"
        case .japanese: "Japanese"
        case .chinese: "Chinese"
        }
    }
}

// MARK: - Transcription engine

/// Backend that powers `TranscriptionSession`. `.local` runs fully on-device
/// via WhisperKit + SpeakerKit. Cloud engines call out to provider APIs for
/// the text and still rely on local SpeakerKit for diarization on the meeting
/// output stream — keeping speaker embeddings off the network.
enum TranscriptionEngine: String, CaseIterable, Identifiable, Sendable {
    case local
    case gemini
    case openai

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .local:  "Local (WhisperKit)"
        case .gemini: "Google Gemini (cloud)"
        case .openai: "OpenAI (cloud)"
        }
    }

    var description: String {
        switch self {
        case .local:
            "Runs entirely on-device. Free, private, slower."
        case .gemini:
            "Sends audio to Google for transcription. Requires API key. Diarization still runs locally via SpeakerKit."
        case .openai:
            "Sends audio to OpenAI's `/v1/audio/transcriptions`. Requires API key + paid OpenAI account. Diarization still runs locally via SpeakerKit."
        }
    }

    /// Glossary primed into cloud providers' system instruction. Bias toward
    /// the iOS/Android mobile-dev vocabulary at Finnomena that gets butchered
    /// when Thai-leaning transcription stumbles on inline English — squad
    /// names, app/repo identifiers, ticket prefixes, mobile stack, auth +
    /// KMP/CMP terms, third-party tooling, and Finnomena product/domain
    /// nouns. User can edit in Settings.
    static let defaultGlossary: String =
        "Finnomena, Mobility, STARLIGHT, FRONTIER, Scrum of Scrum, sprint, grooming, pre-grooming, retro, retrospective, standup, check-in, check-out, postmortem, smoke test, hotfix, rollback, release, MR, PR, code review, QA, deep link, data tagging, data tracking, observability, SAST, BFM, gateway, nter-ios-app, advisor-ios-app, nter-android-app, finnomena-chat, Valhalla, DataTaggingKMP, MOBILITY, STAR, TECHREQ, iOS, Android, Swift, SwiftUI, UIKit, UICollectionView, Xcode, Simulator, Kotlin, KMP, Compose, CMP, UniFFI, Gobley, Rust, Liquid Glass, AppTrackingTransparency, ATT, Kratos, Hydra, OAuth2, passkey, AASA, DAL, MFA, biometric, keychain, Pitch Lock, social login, Fastlane, Fork, Ghostty, GitLab, MobSF, Semgrep, Tailscale, Sentry, Crashlytics, Firebase, Braze, Unleash, Codex, Claude Code, Cursor, BrowserStack, R.swift, Mermaid, port, portfolio, fund, term fund, IPO, SET, NAV, advisor, KYC, onboarding, e-coupon, FPick, F4A, CMS, segregate account, announcement, content card, push notification, Notification Hub, Noti Banner, Noti Hub, Noti Center, bell counter, MFA on Port, Matrix, CallKit"
}

// MARK: - Gemini model

/// Selectable Gemini model for the cloud transcription engine. Backing
/// raw values match Google's API model IDs so they're passed straight
/// into the URL.
enum GeminiModel: String, CaseIterable, Identifiable, Sendable {
    case flash      = "gemini-2.5-flash"
    case flashLite  = "gemini-2.5-flash-lite"
    case pro        = "gemini-2.5-pro"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .flash:     "Gemini 2.5 Flash"
        case .flashLite: "Gemini 2.5 Flash Lite"
        case .pro:       "Gemini 2.5 Pro"
        }
    }

    var description: String {
        switch self {
        case .flash:
            "Fast and cheap. Acceptable on short, clear English audio; quality drops noticeably on Thai-English code-switching versus Pro."
        case .flashLite:
            "Smallest, cheapest. Lowest transcription quality of the three — fine for quick previews, not production transcripts."
        case .pro:
            "Default. Highest transcription quality on Thai-English code-switching content in our testing — beats Flash, Flash-Lite, and every OpenAI model. Slower and more expensive per request, on a separate capacity pool from Flash."
        }
    }
}

// MARK: - OpenAI model

/// Selectable OpenAI transcription model. Raw values are the API model
/// IDs.
enum OpenAIModel: String, CaseIterable, Identifiable, Sendable {
    case gpt4oTranscribe        = "gpt-4o-transcribe"
    case gpt4oMiniTranscribe    = "gpt-4o-mini-transcribe"
    case gpt4oTranscribeDiarize = "gpt-4o-transcribe-diarize"
    case whisper1               = "whisper-1"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .gpt4oTranscribe:        "gpt-4o-transcribe"
        case .gpt4oMiniTranscribe:    "gpt-4o-mini-transcribe"
        case .gpt4oTranscribeDiarize: "gpt-4o-transcribe-diarize"
        case .whisper1:               "whisper-1"
        }
    }

    var description: String {
        switch self {
        case .gpt4oTranscribe:
            "Newest, highest-quality OpenAI transcription model. Best for Thai-English code-switching. Returns text-only (no per-segment timestamps), so each 60s chunk = one segment."
        case .gpt4oMiniTranscribe:
            "Cheaper, smaller variant of gpt-4o-transcribe. Same text-only output."
        case .gpt4oTranscribeDiarize:
            "Native speaker diarization built into the model — returns segments with speaker labels in one call, skips local SpeakerKit. Up to 12.5 min per chunk (capped by the 25 MB request limit). Trade-off: no prompt/glossary support, so technical terms may transcribe less accurately than gpt-4o-transcribe; meetings >12 min get multiple chunks and speaker labels reset per chunk."
        case .whisper1:
            "Original Whisper API. Same architecture as the on-device model but hosted. Returns proper per-segment timestamps via verbose_json — best timestamp accuracy of the three."
        }
    }

    /// API response format the model can actually honor. Only whisper-1
    /// returns segments via `verbose_json`; the gpt-4o-* models reject
    /// it. `gpt-4o-transcribe-diarize` requires the new `diarized_json`
    /// shape that ships speaker labels alongside segment timestamps.
    var apiResponseFormat: String {
        switch self {
        case .whisper1:                                     "verbose_json"
        case .gpt4oTranscribe, .gpt4oMiniTranscribe:        "json"
        case .gpt4oTranscribeDiarize:                       "diarized_json"
        }
    }

    /// Chunk size in seconds. 60 s for every text-only model — matches
    /// Gemini so the two engines can be A/B compared on the same audio
    /// boundary, and keeps every request inside each model's
    /// tight-attention window. The diarize model accepts up to 1400 s
    /// per request, but /v1/audio/transcriptions caps file size at 25 MB
    /// and our chunks are 16 kHz mono 16-bit PCM = 32 KB/s. Hard ceiling
    /// is 819 s (= 25 MB exactly); 750 s leaves ~1.5 MB headroom and
    /// still fits any typical daily standup (10-12 min) in one chunk so
    /// speaker labels stay consistent end to end.
    var chunkDuration: TimeInterval {
        switch self {
        case .gpt4oTranscribeDiarize: 750
        default: 60
        }
    }

    /// True when the model returns speaker-labeled segments natively.
    /// `OpenAIProvider` skips its local SpeakerKit + DiarizationMerger
    /// pipeline for these models and consumes the speaker field on each
    /// `diarized_json` segment directly.
    var supportsNativeDiarization: Bool {
        self == .gpt4oTranscribeDiarize
    }
}

// MARK: - Appearance

enum AppearancePreference: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: "Match system"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// Applies to the running NSApp instance. Idempotent.
    @MainActor
    func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

// MARK: - Auto-record source fallback

/// What auto-record does when source resolution finds no window matching the
/// event's conference URL. `display` records the primary display anyway
/// (default). `skip` cancels the countdown with a toast.
enum AutoRecordSourceFallback: String, CaseIterable, Sendable, Identifiable {
    case display
    case skip

    var id: String { rawValue }

    var label: String {
        switch self {
        case .display: return "Record the primary display instead"
        case .skip:    return "Skip the recording entirely"
        }
    }
}

// MARK: - Video retention

/// How long the library keeps each meeting's `video.mov` before
/// auto-trashing it to reclaim disk space. Only the video file is
/// affected — audio (`mic.wav` / `output.wav`), transcript, marks, and
/// every other artifact are always retained. Starred meetings are exempt
/// from the sweep. Videos go to the Trash, not a hard delete, so they're
/// recoverable.
enum VideoRetention: String, CaseIterable, Identifiable, Sendable {
    case keepForever
    case days3
    case days7
    case days14
    case days30

    var id: String { rawValue }

    /// Maximum video age in seconds, or `nil` when retention is off
    /// (`.keepForever`) — in which case no sweep runs.
    var maxAge: TimeInterval? {
        switch self {
        case .keepForever: return nil
        case .days3:  return 3  * 86_400
        case .days7:  return 7  * 86_400
        case .days14: return 14 * 86_400
        case .days30: return 30 * 86_400
        }
    }

    var displayName: String {
        switch self {
        case .keepForever: "Keep forever"
        case .days3:  "After 3 days"
        case .days7:  "After 7 days"
        case .days14: "After 14 days"
        case .days30: "After 30 days"
        }
    }
}
