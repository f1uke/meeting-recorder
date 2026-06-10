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
        // SpeakerID is RawRepresentable, so it encodes as a bare string.
        let json = """
        { "id": "speaker_0", "displayName": "Speaker 1" }
        """.data(using: .utf8)!
        let profile = try JSONDecoder().decode(SpeakerProfile.self, from: json)
        XCTAssertNil(profile.autoNamedConfidence)
        XCTAssertFalse(profile.autoNamed)
    }
}
