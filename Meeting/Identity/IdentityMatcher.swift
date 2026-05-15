import Foundation

/// Pure scoring engine — no I/O, no state. Easy to test.
///
/// Composite score per (speaker, identity):
///
///     score = 0.65 * embeddingScore        // cosine, clamped ≥ 0
///           + 0.20 * calendarPrior         // 1 if email overlap, else 0
///           + 0.10 * meetNamePrior         // 1 exact, 0.7 fuzzy, else 0
///           + 0.05 * recencyPrior          // exp(-days/30), clamped [0,1]
///
/// After computing scores for every (speaker, identity) pair above the
/// minimum threshold, `match()` does **greedy mutual exclusion**: the
/// highest-scoring pair wins both endpoints, repeat. So one identity is
/// suggested for at most one speaker per meeting.
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

    /// Map a raw score (already filtered ≥ minSuggestScore) to a 50–99 integer
    /// percent for the UI. Linear over [0.45, 1.0]; values outside that range
    /// clamp. Deliberately NOT a probability — the cosine doesn't translate.
    static func confidencePercent(_ score: Double) -> Int {
        let s = max(0.45, min(1.0, score))
        let normalized = (s - 0.45) / (1.0 - 0.45)
        return Int(50 + normalized * 49)
    }

    /// Returns suggestions sorted by score desc, with greedy mutual exclusion
    /// applied so one identity is suggested for at most one speaker.
    static func match(
        embeddings: [SpeakerEmbedding],
        identities: [Identity],
        context: MatchContext,
        rejected: [Rejection],
        config: MatchingConfig = MatchingConfig(),
        now: Date
    ) -> [IdentitySuggestion] {
        let rejectedSet = Set(rejected.map { "\($0.speakerID.rawValue):\($0.identityID)" })

        struct Candidate {
            let speakerID: SpeakerID
            let identity: Identity
            let score: Double
        }
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
                    candidates.append(Candidate(speakerID: speaker.speakerID,
                                                identity: identity, score: s))
                }
            }
        }

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

    /// Iterative Levenshtein distance with two rolling rows — O(n*m) time, O(m) space.
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
