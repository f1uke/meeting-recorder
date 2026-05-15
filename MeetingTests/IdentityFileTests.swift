import XCTest
@testable import Meeting

final class IdentityFileTests: XCTestCase {
    func test_roundTrip_preservesAllFields() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let identity = Identity(
            id: "abc-123",
            displayName: "Sun Sarin",
            emails: ["sun@example.com"],
            centroid: [Float](repeating: 0.1, count: 192),
            sampleSeconds: 142.3,
            seenIn: ["2026-05-15_10-00-00", "2026-05-08_10-00-00"],
            meetingCount: 2,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_001_000)
        )
        let file = IdentityStoreFile(
            schemaVersion: 1,
            embedderModel: "pyannote-v3-w8a16",
            identities: [identity]
        )

        let url = folder.appendingPathComponent("identities.json")
        try file.write(to: url)
        let restored = try IdentityStoreFile.read(from: url)

        XCTAssertEqual(restored.schemaVersion, 1)
        XCTAssertEqual(restored.embedderModel, "pyannote-v3-w8a16")
        XCTAssertEqual(restored.identities.count, 1)
        XCTAssertEqual(restored.identities[0], identity)
    }

    func test_read_missingFile_throws() {
        let url = URL(fileURLWithPath: "/tmp/nonexistent-\(UUID().uuidString).json")
        XCTAssertThrowsError(try IdentityStoreFile.read(from: url))
    }

    private func makeTempFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
