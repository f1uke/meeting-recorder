import XCTest
import WhisperKit
@testable import Meeting

/// These tests load the real argmax Core ML embedder. They skip when the
/// models aren't downloaded — run `LocalProvider` against any meeting once to
/// populate `~/Library/Application Support/dev.fluke.meeting/Models/`.
final class SpeakerEmbedderIntegrationTests: XCTestCase {
    func test_embed_returnsL2NormalizedVector_atOutputDim() async throws {
        guard let fixtureURL = Self.fixtureURL() else {
            throw XCTSkip("Fixture missing — see MeetingTests/fixtures/README")
        }
        guard SpeakerEmbedder.modelsAvailable() else {
            throw XCTSkip("Pyannote models not downloaded — run LocalProvider transcribe once")
        }

        let audio = try AudioProcessor.loadAudioAsFloatArray(
            fromPath: fixtureURL.path(percentEncoded: false),
            channelMode: .sumChannels(nil)
        )
        let embedder = SpeakerEmbedder()
        try await embedder.loadModels()

        let result = try await embedder.embed(audioSegments: [audio])
        let v = try XCTUnwrap(result, "embedding nil — audio too short?")
        XCTAssertEqual(v.count, SpeakerEmbedder.outputDim,
                       "argmax may have shipped a new pyannote variant — update SpeakerEmbedder.outputDim")
        let norm = sqrt(v.reduce(into: Float(0)) { $0 += $1 * $1 })
        XCTAssertEqual(norm, 1.0, accuracy: 0.001)

        await embedder.unloadModels()
    }

    func test_embed_belowMinDuration_returnsNil() async throws {
        guard SpeakerEmbedder.modelsAvailable() else {
            throw XCTSkip("Pyannote models not downloaded")
        }
        // 4 seconds < min 5s
        let short: [Float] = [Float](repeating: 0.0, count: 64_000)
        let embedder = SpeakerEmbedder()
        try await embedder.loadModels()
        let result = try await embedder.embed(audioSegments: [short])
        XCTAssertNil(result)
        await embedder.unloadModels()
    }

    private static func fixtureURL() -> URL? {
        // Try bundle first, then fall back to repo-relative path during dev
        if let url = Bundle(for: SpeakerEmbedderIntegrationTests.self)
            .url(forResource: "two-speaker-5s", withExtension: "wav") {
            return url
        }
        // Walk up from this source file's path
        let here = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("fixtures")
            .appendingPathComponent("two-speaker-5s.wav")
        return FileManager.default.fileExists(atPath: here.path) ? here : nil
    }
}
