import XCTest
@testable import Meeting

final class IdentityMatcherTests: XCTestCase {
    func test_embeddingScore_identicalUnitVectors_isOne() {
        let v = SpeakerEmbedderHelpers.l2Normalize([1, 2, 3, 4])
        XCTAssertEqual(IdentityMatcher.embeddingScore(speaker: v, identity: v), 1.0, accuracy: 0.001)
    }

    func test_embeddingScore_oppositeVectors_clampsToZero() {
        let a = SpeakerEmbedderHelpers.l2Normalize([1, 2, 3, 4])
        let b = SpeakerEmbedderHelpers.l2Normalize([-1, -2, -3, -4])
        XCTAssertEqual(IdentityMatcher.embeddingScore(speaker: a, identity: b), 0.0)
    }

    func test_calendarPrior_matchEmail_is1_else0() {
        let ctx = MatchContext(
            attendeeEmails: ["sun@example.com"],
            meetParticipantNames: [],
            meetingFolder: "M"
        )
        XCTAssertEqual(IdentityMatcher.calendarPrior(
            identity: identity(name: "X", emails: ["sun@example.com"]),
            context: ctx
        ), 1.0)
        XCTAssertEqual(IdentityMatcher.calendarPrior(
            identity: identity(name: "Y", emails: ["other@example.com"]),
            context: ctx
        ), 0.0)
        XCTAssertEqual(IdentityMatcher.calendarPrior(
            identity: identity(name: "Z", emails: []),
            context: ctx
        ), 0.0)
    }

    func test_meetNamePrior_exact_is1_fuzzy_is07_else0() {
        let ctx = MatchContext(
            attendeeEmails: [],
            meetParticipantNames: ["Sun Sarin", "Pim"],
            meetingFolder: "M"
        )
        XCTAssertEqual(IdentityMatcher.meetNamePrior(
            identity: identity(name: "sun sarin"), context: ctx), 1.0)
        // "Sunsarine" vs "Sun Sarin" — distance = 2 (insert 'e', delete ' ') / max len 9 = 0.778
        // Actually Levenshtein("Sunsarine", "Sun Sarin") = 2; ratio = 1 - 2/9 = 0.778 → < 0.85
        // Use a closer fuzzy candidate:
        XCTAssertEqual(IdentityMatcher.meetNamePrior(
            identity: identity(name: "Sun Sarin "), context: ctx), 1.0,
            "trailing space — trim makes exact")
        // Real fuzzy: 1 typo on a short string
        let ctx2 = MatchContext(
            attendeeEmails: [],
            meetParticipantNames: ["Suriya"],
            meetingFolder: "M"
        )
        // "Suriyo" vs "Suriya" → distance 1 / max 6 → 0.833 → < 0.85 (just below threshold)
        // "Sunya" vs "Suriya" → distance 2 / max 6 → 0.667 → < 0.85
        // "Suriya" vs "Suriya " → distance 0 after trim → exact
        // Use longer name for clearer fuzzy: "Sun Sarin" vs "Sun Sarinn"
        let ctx3 = MatchContext(
            attendeeEmails: [],
            meetParticipantNames: ["Sun Sarinn"],
            meetingFolder: "M"
        )
        // Levenshtein("sun sarin", "sun sarinn") = 1 / max 10 = 0.9 → ≥ 0.85
        XCTAssertEqual(IdentityMatcher.meetNamePrior(
            identity: identity(name: "Sun Sarin"), context: ctx3), 0.7, accuracy: 0.001)
        XCTAssertEqual(IdentityMatcher.meetNamePrior(
            identity: identity(name: "Aon"), context: ctx), 0.0)
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
        let centroid = SpeakerEmbedderHelpers.l2Normalize([1, 2, 3, 4])
        let now = Date()
        let identity = identity(
            name: "Sun Sarin",
            centroid: centroid,
            emails: ["sun@example.com"],
            lastSeenDaysAgo: 1,
            now: now
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
            speaker: speakerEmb, identity: identity, context: ctx, now: now
        )
        XCTAssertEqual(score, 1.0, accuracy: 0.02)
    }

    func test_match_filtersBelowThreshold() {
        let c1 = SpeakerEmbedderHelpers.l2Normalize([1, 2, 3, 4])
        let c2 = SpeakerEmbedderHelpers.l2Normalize([-1, -2, -3, -4])
        let identity = identity(name: "X", centroid: c2)
        let speakerEmb = SpeakerEmbedding(
            speakerID: SpeakerID.diarized(0), centroid: c1, sampleSeconds: 30
        )
        let suggestions = IdentityMatcher.match(
            embeddings: [speakerEmb],
            identities: [identity],
            context: MatchContext(attendeeEmails: [], meetParticipantNames: [], meetingFolder: "M"),
            rejected: [],
            config: MatchingConfig(),
            now: Date()
        )
        XCTAssertTrue(suggestions.isEmpty, "opposite cosine — below threshold")
    }

    func test_match_mutualExclusion_oneIdentityClaimedAtMostOnce() {
        let c1 = SpeakerEmbedderHelpers.l2Normalize([1, 0, 0, 0])
        let identity1 = identity(name: "A", centroid: c1)
        // Two speakers, only one identity available
        let speaker0 = SpeakerEmbedding(speakerID: SpeakerID.diarized(0), centroid: c1, sampleSeconds: 60)
        let speaker1 = SpeakerEmbedding(speakerID: SpeakerID.diarized(1), centroid: c1, sampleSeconds: 60)

        let suggestions = IdentityMatcher.match(
            embeddings: [speaker0, speaker1],
            identities: [identity1],
            context: MatchContext(attendeeEmails: [], meetParticipantNames: [], meetingFolder: "M"),
            rejected: [],
            config: MatchingConfig(),
            now: Date()
        )
        XCTAssertLessThanOrEqual(Set(suggestions.map { $0.identityID }).count, 1)
        XCTAssertEqual(suggestions.count, 1, "identity1 claimed once")
    }

    func test_match_skipsRejected() {
        let c = SpeakerEmbedderHelpers.l2Normalize([1, 2, 3, 4])
        let iden = identity(name: "A", centroid: c)
        let speaker = SpeakerEmbedding(speakerID: SpeakerID.diarized(0), centroid: c, sampleSeconds: 60)
        let suggestions = IdentityMatcher.match(
            embeddings: [speaker],
            identities: [iden],
            context: MatchContext(attendeeEmails: [], meetParticipantNames: [], meetingFolder: "M"),
            rejected: [Rejection(speakerID: SpeakerID.diarized(0), identityID: iden.id)],
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
