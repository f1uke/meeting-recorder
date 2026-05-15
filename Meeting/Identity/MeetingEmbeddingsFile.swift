import Foundation

/// 192-dim L2-normalized centroid for a single diarized speaker in a meeting.
struct SpeakerEmbedding: Codable, Hashable, Sendable {
    let speakerID: SpeakerID
    let centroid: [Float]
    let sampleSeconds: Double
}

/// User said "speaker_N is NOT identity X" — never suggest that pair again
/// for this meeting. Scoped per-meeting (not global) to keep V1 simple.
struct Rejection: Codable, Hashable, Sendable {
    let speakerID: SpeakerID
    let identityID: String
}

/// On-disk shape of `<meeting>/embeddings.json`.
///
/// Lives next to `transcript.json` / `speakers.json`. Safe to delete: the
/// `EmbeddingExtractionQueue` will regenerate on the next Library scan.
struct MeetingEmbeddingsFile: Codable, Hashable, Sendable {
    static let filename = "embeddings.json"

    var schemaVersion: Int
    var embedderModel: String
    var embeddings: [SpeakerEmbedding]
    var rejectedIdentities: [Rejection]
    var embeddingFailed: Bool

    static func read(from folder: URL) throws -> MeetingEmbeddingsFile {
        let url = folder.appendingPathComponent(filename)
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(MeetingEmbeddingsFile.self, from: data)
    }

    func write(to folder: URL) throws {
        let url = folder.appendingPathComponent(Self.filename)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: [.atomic])
    }

    mutating func appendRejection(_ r: Rejection) {
        guard !rejectedIdentities.contains(r) else { return }
        rejectedIdentities.append(r)
    }
}
