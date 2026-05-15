import Foundation
import AppKit

/// Polls `NSPasteboard.general.changeCount` once a second during a
/// recording and pushes each new clipboard payload into the shared
/// `ContextCollector`. Captures three payload kinds:
///
///   - URL  (preferred when present — covers the "copied a link" case)
///   - text (plain string)
///   - image (saved to `<meeting>/clipboard/<uuid>.png`)
///
/// Each `pasteboard.string` / `pasteboard.data` read on macOS 14+ counts
/// as a clipboard access and may surface a system notification on the
/// first read after a paste from another app. The user is told what
/// this watcher does in Settings; a single dialog at first run is the
/// expected UX.
@MainActor
final class ClipboardWatcher {
    private let collector: ContextCollector
    private let imagesFolder: URL
    private var timer: Timer?
    private var lastChangeCount: Int

    init(collector: ContextCollector, meetingFolder: URL) {
        self.collector = collector
        self.imagesFolder = ContextCaptureFile.imagesFolder(in: meetingFolder)
        // Snapshot the current changeCount so whatever the user had
        // copied *before* recording started doesn't get captured on the
        // first tick.
        self.lastChangeCount = NSPasteboard.general.changeCount
    }

    func start(interval: TimeInterval = 1.0) {
        let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Internals

    private func poll() {
        let pb = NSPasteboard.general
        let count = pb.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count
        let now = Date()

        // URL takes precedence — Finder and most browsers stamp both
        // `.URL` and `.string` onto a URL copy; we want the structured
        // form so the UI can render an icon + favicon-style chip.
        if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [NSURL],
           let first = urls.first as URL?,
           !first.absoluteString.isEmpty {
            let urlString = first.absoluteString
            Task { [collector] in
                await collector.append(
                    kind: .url,
                    source: .clipboard,
                    text: urlString,
                    at: now
                )
            }
            NSLog("[Meeting/Clipboard] captured url: %@", urlString)
            return
        }

        // Image: convert the system's TIFF representation to PNG so the
        // saved file is portable and lossless. Skip when there's also a
        // string payload that looks like a path (file copies in Finder
        // produce both — string would be the absolute path).
        if let image = NSImage(pasteboard: pb),
           let png = pngData(from: image) {
            let filename = "\(UUID().uuidString).png"
            do {
                try FileManager.default.createDirectory(
                    at: imagesFolder, withIntermediateDirectories: true
                )
                try png.write(to: imagesFolder.appendingPathComponent(filename))
                Task { [collector] in
                    await collector.append(
                        kind: .image,
                        source: .clipboard,
                        imageFilename: filename,
                        at: now
                    )
                }
                NSLog("[Meeting/Clipboard] captured image: %@ (%d bytes)",
                      filename, png.count)
            } catch {
                NSLog("[Meeting/Clipboard] image write failed: %@",
                      String(describing: error))
            }
            return
        }

        // Plain text — drop empty / whitespace-only payloads (a Cmd+C
        // on nothing-selected surfaces an empty string in some apps).
        if let text = pb.string(forType: .string) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            // Some sources (chat apps, terminals, "Copy URL" in apps that
            // don't stamp `public.url`) put the URL only on the string
            // flavor of the pasteboard, so `readObjects(forClasses:[NSURL])`
            // above misses it and we'd otherwise classify it as plain
            // text. If the trimmed content is exactly one well-formed
            // http(s) URL, promote it to .url so the summary prompt's
            // Jira / Confluence fetch rules apply.
            if Self.isStandaloneURL(trimmed) {
                Task { [collector] in
                    await collector.append(
                        kind: .url,
                        source: .clipboard,
                        text: trimmed,
                        at: now
                    )
                }
                NSLog("[Meeting/Clipboard] captured url (from text flavor): %@", trimmed)
                return
            }
            Task { [collector] in
                await collector.append(
                    kind: .text,
                    source: .clipboard,
                    text: text,
                    at: now
                )
            }
            NSLog("[Meeting/Clipboard] captured text: %d chars", text.count)
        }
    }

    /// True when `s` is exactly one well-formed http(s) URL with a host
    /// — no surrounding text, no inner whitespace. We use the precise
    /// shape because `URL(string:)` is permissive (e.g. it accepts
    /// "hello world" as a relative path), and we'd rather under-promote
    /// than mis-promote a chat sentence into a URL chip.
    private static func isStandaloneURL(_ s: String) -> Bool {
        guard !s.contains(where: { $0.isWhitespace || $0.isNewline }) else { return false }
        let lower = s.lowercased()
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://") else { return false }
        guard let url = URL(string: s),
              let host = url.host, !host.isEmpty else { return false }
        return true
    }

    private func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
