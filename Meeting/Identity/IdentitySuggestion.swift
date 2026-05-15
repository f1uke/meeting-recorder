import Foundation

/// Output of `IdentityMatcher.match()` — one row per (speaker_N, identity) candidate.
struct IdentitySuggestion: Hashable, Sendable, Identifiable {
    let speakerID: SpeakerID
    let identityID: String
    let identityDisplayName: String
    let score: Double
    let confidencePercent: Int
    var id: String { "\(speakerID.rawValue):\(identityID)" }
}

/// Per-meeting context that the matcher uses for its non-acoustic priors.
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

/// Weights + threshold for the matcher. Exposed so AppPreferences can override
/// `minSuggestScore` from the Settings slider.
struct MatchingConfig: Sendable {
    var minSuggestScore: Double = 0.45
    var highConfidenceScore: Double = 0.65
    var maxSuggestionsPerSpeaker: Int = 3
    var embeddingWeight: Double = 0.65
    var calendarWeight: Double = 0.20
    var meetNameWeight: Double = 0.10
    var recencyWeight: Double = 0.05
    var recencyDecayDays: Double = 30
}
