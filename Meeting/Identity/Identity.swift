import Foundation

/// One person across all meetings. Centroid is the running mean of their
/// pyannote v3 embeddings, weighted by `sampleSeconds`.
struct Identity: Codable, Hashable, Sendable, Identifiable {
    let id: String
    var displayName: String
    var emails: [String]
    var centroid: [Float]
    var sampleSeconds: Double
    var seenIn: [String]
    var meetingCount: Int
    var createdAt: Date
    var updatedAt: Date
}

/// On-disk shape of `~/Library/Application Support/dev.fluke.meeting/identities.json`.
struct IdentityStoreFile: Codable, Sendable {
    var schemaVersion: Int
    var embedderModel: String
    var identities: [Identity]

    init(schemaVersion: Int = 1, embedderModel: String, identities: [Identity] = []) {
        self.schemaVersion = schemaVersion
        self.embedderModel = embedderModel
        self.identities = identities
    }

    static func read(from url: URL) throws -> IdentityStoreFile {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(IdentityStoreFile.self, from: data)
    }

    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: url, options: [.atomic])
    }
}
