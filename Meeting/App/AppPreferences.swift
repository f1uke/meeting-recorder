import Foundation
import Combine

/// User-configurable knobs that persist across launches via UserDefaults.
/// Kept lean; expand as the Settings UI grows.
@MainActor
final class AppPreferences: ObservableObject {
    static let shared = AppPreferences()

    @Published var expectedSpeakerCount: ExpectedSpeakers {
        didSet {
            UserDefaults.standard.set(
                expectedSpeakerCount.storageValue,
                forKey: Keys.expectedSpeakers
            )
        }
    }

    private init() {
        let raw = UserDefaults.standard.object(forKey: Keys.expectedSpeakers) as? Int
        self.expectedSpeakerCount = ExpectedSpeakers(storageValue: raw)
    }

    private enum Keys {
        static let expectedSpeakers = "dev.fluke.meeting.expectedSpeakers"
    }
}

/// User's expectation for how many participants will be speaking in the meeting
/// audio. Drives PyannoteDiarizationOptions.numberOfSpeakers.
enum ExpectedSpeakers: Hashable, CaseIterable {
    case auto
    case exact(Int)

    static let allCases: [ExpectedSpeakers] = [
        .auto, .exact(1), .exact(2), .exact(3), .exact(4), .exact(5), .exact(6)
    ]

    /// Value to feed to PyannoteDiarizationOptions.numberOfSpeakers (`nil` = auto).
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

    /// Roundtrip into UserDefaults: -1 = auto, otherwise the speaker count.
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
