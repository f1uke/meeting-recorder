import Foundation

/// Centralised location for the CoreML models WhisperKit / SpeakerKit pull
/// from HuggingFace. The library default would dump them under
/// `~/Documents/huggingface/` — that gets iCloud-synced on most setups
/// (3 GB+ uploaded for nothing), so we redirect to Application Support
/// where macOS expects opaque app data.
enum ModelStorage {
    /// `~/Library/Application Support/dev.fluke.meeting/Models/`
    /// Created on first access; safe to call from any thread.
    static func downloadBase() -> URL {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let bundleID = Bundle.main.bundleIdentifier ?? "dev.fluke.meeting"
        let url = support
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
        if !fm.fileExists(atPath: url.path(percentEncoded: false)) {
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    /// Total bytes of cached models, useful for a "manage storage" UI later.
    static func cacheSize() -> Int64 {
        let url = downloadBase()
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true {
                total += Int64(values?.fileSize ?? 0)
            }
        }
        return total
    }
}
