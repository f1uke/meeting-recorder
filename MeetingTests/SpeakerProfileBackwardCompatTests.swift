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

    func test_decode_omittedIdentityIDField_isNil() throws {
        let json = """
        {
          "id": "speaker_0",
          "displayName": "X"
        }
        """
        let data = Data(json.utf8)
        let profile = try JSONDecoder().decode(SpeakerProfile.self, from: data)
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
