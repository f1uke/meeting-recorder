import XCTest
@testable import Meeting

final class MeetingEmbeddingsFileTests: XCTestCase {
    func test_roundTrip() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let file = MeetingEmbeddingsFile(
            schemaVersion: 1,
            embedderModel: "pyannote-v3-w8a16",
            embeddings: [
                SpeakerEmbedding(
                    speakerID: SpeakerID.diarized(0),
                    centroid: [Float](repeating: 0.1, count: 192),
                    sampleSeconds: 60
                )
            ],
            rejectedIdentities: [
                Rejection(speakerID: SpeakerID.diarized(0), identityID: "abc")
            ],
            embeddingFailed: false
        )
        try file.write(to: folder)
        let restored = try MeetingEmbeddingsFile.read(from: folder)
        XCTAssertEqual(restored, file)
    }

    func test_appendRejection_doesNotDuplicate() throws {
        var file = MeetingEmbeddingsFile(
            schemaVersion: 1,
            embedderModel: "pyannote-v3-w8a16",
            embeddings: [],
            rejectedIdentities: [],
            embeddingFailed: false
        )
        let rej = Rejection(speakerID: SpeakerID.diarized(0), identityID: "abc")
        file.appendRejection(rej)
        file.appendRejection(rej)
        XCTAssertEqual(file.rejectedIdentities.count, 1)
    }

    func test_appendRejection_appendsDistinct() {
        var file = MeetingEmbeddingsFile(
            schemaVersion: 1,
            embedderModel: "pyannote-v3-w8a16",
            embeddings: [],
            rejectedIdentities: [],
            embeddingFailed: false
        )
        file.appendRejection(Rejection(speakerID: SpeakerID.diarized(0), identityID: "abc"))
        file.appendRejection(Rejection(speakerID: SpeakerID.diarized(0), identityID: "def"))
        file.appendRejection(Rejection(speakerID: SpeakerID.diarized(1), identityID: "abc"))
        XCTAssertEqual(file.rejectedIdentities.count, 3)
    }

    private func makeTempFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
