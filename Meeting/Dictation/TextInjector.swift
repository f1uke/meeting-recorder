import AppKit
import CoreGraphics

/// Injects transcribed text into whatever field currently has focus in the
/// frontmost app, by round-tripping through the general pasteboard and
/// posting a synthetic Command-V. Save/restore keeps the user's clipboard
/// intact. Never activates this app, so the target field keeps focus.
enum TextInjector {
    /// Concatenate segment texts into one clean line: trim each, join with a
    /// single space, collapse internal whitespace runs.
    static func joinSegments(_ segments: [TranscriptSegment]) -> String {
        let joined = segments
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let collapsed = joined
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed
    }

    /// Snapshot the current pasteboard string (nil if none).
    static func snapshotString() -> String? {
        NSPasteboard.general.string(forType: .string)
    }

    /// Restore a previously snapshotted string, clearing whatever we wrote.
    static func restoreString(_ saved: String?) {
        let pb = NSPasteboard.general
        pb.clearContents()
        if let saved { pb.setString(saved, forType: .string) }
    }

    /// Paste `text` at the current cursor. No-op if blank.
    @MainActor
    static func inject(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let saved = snapshotString()
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(trimmed, forType: .string)

        postCommandV()

        // Restore after the paste has read the pasteboard. 120ms is enough
        // for the frontmost app to service the Command-V; sooner risks
        // pasting the restored (old) value.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            restoreString(saved)
        }
    }

    private static func postCommandV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9  // 'v'
        let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cgSessionEventTap)
        up?.post(tap: .cgSessionEventTap)
    }
}
