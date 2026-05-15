import XCTest
@testable import Meeting

@MainActor
final class IdentityStoreTests: XCTestCase {
    func test_emptyStore_loadsClean() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = IdentityStore(fileURL: folder.appendingPathComponent("identities.json"))
        XCTAssertTrue(store.identities.isEmpty)
        XCTAssertEqual(store.embedderModel, SpeakerEmbedder.modelTag)
    }

    func test_create_persistsAndReloads() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("identities.json")

        let store = IdentityStore(fileURL: url)
        let id = store.create(
            displayName: "Sun Sarin",
            email: nil,
            centroid: unitVector(seed: 1, dim: 192),
            sampleSeconds: 60,
            meetingFolder: "2026-05-15_10-00-00"
        )

        let store2 = IdentityStore(fileURL: url)
        XCTAssertEqual(store2.identities.count, 1)
        XCTAssertEqual(store2.identities[0].id, id)
        XCTAssertEqual(store2.identities[0].displayName, "Sun Sarin")
        XCTAssertEqual(store2.identities[0].meetingCount, 1)
    }

    func test_updateCentroid_runningMeanWeightsBySampleSeconds() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = IdentityStore(fileURL: folder.appendingPathComponent("identities.json"))

        let c1 = unitVector(seed: 1, dim: 192)
        let c2 = unitVector(seed: 2, dim: 192)
        let id = store.create(
            displayName: "X",
            email: nil,
            centroid: c1,
            sampleSeconds: 30,
            meetingFolder: "A"
        )
        store.updateCentroid(id: id, newCentroid: c2, newSampleSeconds: 90, meetingFolder: "B")

        let updated = store.identities[0]
        XCTAssertEqual(updated.sampleSeconds, 120, accuracy: 0.01)
        XCTAssertEqual(updated.meetingCount, 2)
        XCTAssertEqual(updated.seenIn, ["B", "A"])
        let norm = sqrt(updated.centroid.reduce(into: Float(0)) { $0 += $1 * $1 })
        XCTAssertEqual(norm, 1.0, accuracy: 0.001)
    }

    func test_delete_removesIdentity() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = IdentityStore(fileURL: folder.appendingPathComponent("identities.json"))

        let id = store.create(
            displayName: "X",
            email: nil,
            centroid: unitVector(seed: 1, dim: 192),
            sampleSeconds: 10,
            meetingFolder: "A"
        )
        store.delete(id: id)
        XCTAssertTrue(store.identities.isEmpty)
    }

    func test_corruptFile_backsUpAndStartsFresh() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("identities.json")
        try Data("not json".utf8).write(to: url)

        let store = IdentityStore(fileURL: url)
        XCTAssertTrue(store.identities.isEmpty)
        let backups = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasPrefix("identities.json.corrupt-") }
        XCTAssertEqual(backups.count, 1)
    }

    // MARK: - Helpers

    private func makeTempFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func unitVector(seed: Int, dim: Int) -> [Float] {
        var v = (0..<dim).map { Float(sin(Double(seed * 17 + $0))) }
        let norm = sqrt(v.reduce(into: Float(0)) { $0 += $1 * $1 })
        for i in 0..<v.count { v[i] /= norm }
        return v
    }
}
