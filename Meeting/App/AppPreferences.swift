import Foundation
import Combine
import AppKit

/// User-configurable knobs that persist across launches via UserDefaults.
/// One central source of truth for everything Settings exposes.
@MainActor
final class AppPreferences: ObservableObject {
    static let shared = AppPreferences()

    @Published var expectedSpeakerCount: ExpectedSpeakers {
        didSet { UserDefaults.standard.set(expectedSpeakerCount.storageValue, forKey: Keys.expectedSpeakers) }
    }

    /// Stable device UID picked in Settings → Recording. `nil` = follow the
    /// system default input device. Persisted as String?; `MicRecorder`
    /// applies it when starting the audio engine.
    @Published var micDeviceUID: String? {
        didSet { UserDefaults.standard.set(micDeviceUID, forKey: Keys.micDeviceUID) }
    }

    @Published var modelVariant: ModelVariant {
        didSet { UserDefaults.standard.set(modelVariant.rawValue, forKey: Keys.modelVariant) }
    }

    @Published var transcriptionLanguage: TranscriptionLanguage {
        didSet { UserDefaults.standard.set(transcriptionLanguage.rawValue, forKey: Keys.transcriptionLanguage) }
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

    private init() {
        let raw = UserDefaults.standard.object(forKey: Keys.expectedSpeakers) as? Int
        self.expectedSpeakerCount = ExpectedSpeakers(storageValue: raw)
        self.micDeviceUID = UserDefaults.standard.string(forKey: Keys.micDeviceUID)
        self.modelVariant = ModelVariant(
            rawValue: UserDefaults.standard.string(forKey: Keys.modelVariant) ?? ""
        ) ?? .largeV3
        self.transcriptionLanguage = TranscriptionLanguage(
            rawValue: UserDefaults.standard.string(forKey: Keys.transcriptionLanguage) ?? ""
        ) ?? .thai
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

    private enum Keys {
        static let expectedSpeakers = "dev.fluke.meeting.expectedSpeakers"
        static let micDeviceUID = "dev.fluke.meeting.micDeviceUID"
        static let modelVariant = "dev.fluke.meeting.modelVariant"
        static let transcriptionLanguage = "dev.fluke.meeting.transcriptionLanguage"
        static let showMenuBarTimer = "dev.fluke.meeting.showMenuBarTimer"
        static let appearance = "dev.fluke.meeting.appearance"
        static let myEmails = "dev.fluke.meeting.myEmails"
    }
}

// MARK: - Expected speaker count

/// User's expectation for how many participants will be speaking in the meeting
/// audio. Drives PyannoteDiarizationOptions.numberOfSpeakers.
enum ExpectedSpeakers: Hashable, CaseIterable {
    case auto
    case exact(Int)

    static let allCases: [ExpectedSpeakers] = [
        .auto, .exact(1), .exact(2), .exact(3), .exact(4), .exact(5), .exact(6)
    ]

    var pyannoteValue: Int? {
        switch self {
        case .auto: nil
        case .exact(let n): n
        }
    }

    var displayName: String {
        switch self {
        case .auto: "Auto detect"
        case .exact(1): "Solo (1 speaker)"
        case .exact(let n): "\(n) speakers"
        }
    }

    var storageValue: Int {
        switch self {
        case .auto: -1
        case .exact(let n): n
        }
    }

    init(storageValue: Int?) {
        guard let raw = storageValue, raw > 0 else {
            self = .auto
            return
        }
        self = .exact(raw)
    }
}

// MARK: - Whisper model variant

/// Whisper model size + quantization. Larger = more accurate but slower.
/// `large-v3-turbo` is ~4× faster than `large-v3` but its language detection
/// has been observed to misclassify Thai as English when set to auto.
enum ModelVariant: String, CaseIterable, Identifiable, Sendable {
    case largeV3 = "large-v3"
    case largeV3Turbo = "large-v3-turbo"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .largeV3: "Large v3 (accurate)"
        case .largeV3Turbo: "Large v3 Turbo (fast)"
        }
    }

    var description: String {
        switch self {
        case .largeV3: "Best for Thai / multilingual content. ~3-5× real-time."
        case .largeV3Turbo: "~10-15× real-time. Risk of mis-detecting Thai as English when language is Auto."
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
