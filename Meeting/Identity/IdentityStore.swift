import Foundation
import Combine
import Accelerate

/// In-memory view of `identities.json` — the global cross-meeting speaker store.
///
/// All mutations go through this class so the on-disk file stays in sync. Writes
/// are atomic (`Data.write(options: .atomic)`); a corrupt file is moved aside as
/// `identities.json.corrupt-<unix-ts>` and the in-memory store starts fresh.
@MainActor
final class IdentityStore: ObservableObject {
    @Published private(set) var identities: [Identity] = []
    let embedderModel: String
    private let fileURL: URL
    private let seenInCap = 50

    init(fileURL: URL, embedderModel: String = SpeakerEmbedder.modelTag) {
        self.fileURL = fileURL
        self.embedderModel = embedderModel
        load()
    }

    // MARK: - Persistence

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else {
            return
        }
        do {
            let file = try IdentityStoreFile.read(from: fileURL)
            if file.embedderModel == embedderModel {
                identities = file.identities
            } else {
                NSLog("[Meeting/Identity] embedderModel mismatch (stored=%@ current=%@) — keeping in-memory empty store",
                      file.embedderModel, embedderModel)
            }
        } catch {
            let backup = fileURL.deletingLastPathComponent()
                .appendingPathComponent("identities.json.corrupt-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            NSLog("[Meeting/Identity] identities.json parse failed (backed up to %@): %@",
                  backup.lastPathComponent, String(describing: error))
        }
    }

    private func save() {
        let file = IdentityStoreFile(
            schemaVersion: 1,
            embedderModel: embedderModel,
            identities: identities
        )
        do {
            try file.write(to: fileURL)
        } catch {
            NSLog("[Meeting/Identity] identities.json write failed: %@", String(describing: error))
        }
    }

    // MARK: - Mutations

    @discardableResult
    func create(
        displayName: String,
        email: String?,
        centroid: [Float],
        sampleSeconds: Double,
        meetingFolder: String
    ) -> String {
        let now = Date()
        let id = UUID().uuidString
        let identity = Identity(
            id: id,
            displayName: displayName,
            emails: email.map { [$0.lowercased()] } ?? [],
            centroid: l2Normalize(centroid),
            sampleSeconds: sampleSeconds,
            seenIn: [meetingFolder],
            meetingCount: 1,
            createdAt: now,
            updatedAt: now
        )
        identities.append(identity)
        save()
        return id
    }

    /// Blend `newCentroid` into the existing one weighted by `sampleSeconds`.
    /// Result is re-normalized (weighted-avg of unit vectors ≠ unit vector).
    func updateCentroid(
        id: String,
        newCentroid: [Float],
        newSampleSeconds: Double,
        meetingFolder: String
    ) {
        guard let idx = identities.firstIndex(where: { $0.id == id }) else { return }
        var iden = identities[idx]
        let wOld = iden.sampleSeconds
        let wNew = newSampleSeconds
        let total = wOld + wNew
        var blended = [Float](repeating: 0, count: iden.centroid.count)
        for i in 0..<blended.count {
            blended[i] = Float((Double(iden.centroid[i]) * wOld
                              + Double(newCentroid[i]) * wNew) / total)
        }
        iden.centroid = l2Normalize(blended)
        iden.sampleSeconds = total
        var seen = iden.seenIn.filter { $0 != meetingFolder }
        seen.insert(meetingFolder, at: 0)
        iden.seenIn = Array(seen.prefix(seenInCap))
        iden.meetingCount += 1
        iden.updatedAt = Date()
        identities[idx] = iden
        save()
    }

    func updateDisplayName(id: String, newName: String) {
        guard let idx = identities.firstIndex(where: { $0.id == id }) else { return }
        identities[idx].displayName = newName
        identities[idx].updatedAt = Date()
        save()
    }

    func addEmail(id: String, email: String) {
        let lc = email.lowercased()
        guard let idx = identities.firstIndex(where: { $0.id == id }),
              !identities[idx].emails.contains(lc) else { return }
        identities[idx].emails.append(lc)
        identities[idx].updatedAt = Date()
        save()
    }

    func delete(id: String) {
        identities.removeAll { $0.id == id }
        save()
    }

    func reset() {
        identities = []
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: - Helpers

    private func l2Normalize(_ v: [Float]) -> [Float] {
        var sumSq: Float = 0
        vDSP_svesq(v, 1, &sumSq, vDSP_Length(v.count))
        let norm = sqrt(sumSq)
        guard norm > 0 else { return v }
        var divisor = norm
        var out = [Float](repeating: 0, count: v.count)
        vDSP_vsdiv(v, 1, &divisor, &out, 1, vDSP_Length(v.count))
        return out
    }
}
