import Foundation

/// Writes a merged transcript out to disk in three formats:
///   - transcript.json  — canonical structured form, round-trippable
///   - transcript.md    — human readable with [hh:mm:ss] timestamps + speaker
///   - transcript.srt   — standard subtitle file for video players
enum TranscriptExporter {
    static func writeAll(_ transcript: MergedTranscript, in folder: URL) throws {
        try writeJSON(transcript, to: folder.appendingPathComponent("transcript.json"))
        try writeMarkdown(transcript, to: folder.appendingPathComponent("transcript.md"))
        try writeSRT(transcript, to: folder.appendingPathComponent("transcript.srt"))
    }

    // MARK: - JSON

    static func writeJSON(_ transcript: MergedTranscript, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(transcript)
        try data.write(to: url, options: [.atomic])
    }

    // MARK: - Markdown

    static func renderMarkdown(_ transcript: MergedTranscript) -> String {
        var lines: [String] = []
        lines.append("# Meeting transcript")
        lines.append("")
        lines.append("- Duration: \(timestamp(transcript.duration))")
        if let lang = transcript.language { lines.append("- Language: \(lang)") }
        lines.append("- Providers: \(transcript.providers.joined(separator: ", "))")
        lines.append("- Speakers:")
        for s in transcript.speakers {
            lines.append("  - \(s.displayName) (`\(s.id.rawValue)`)")
        }
        lines.append("")
        lines.append("---")
        lines.append("")

        let names = Dictionary(uniqueKeysWithValues: transcript.speakers.map { ($0.id, $0.displayName) })
        for seg in transcript.segments {
            let label = names[seg.speaker] ?? seg.speaker.rawValue
            let ts = "[\(timestamp(seg.start)) – \(timestamp(seg.end))]"
            lines.append("**\(label)** \(ts)")
            lines.append("")
            lines.append(seg.text)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    static func writeMarkdown(_ transcript: MergedTranscript, to url: URL) throws {
        let md = renderMarkdown(transcript)
        try md.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - SRT

    static func renderSRT(_ transcript: MergedTranscript) -> String {
        let names = Dictionary(uniqueKeysWithValues: transcript.speakers.map { ($0.id, $0.displayName) })
        var blocks: [String] = []
        for (i, seg) in transcript.segments.enumerated() {
            let label = names[seg.speaker] ?? seg.speaker.rawValue
            let ts = "\(srtTimestamp(seg.start)) --> \(srtTimestamp(seg.end))"
            // SRT supports a single line of text per cue (most players merge \n).
            // We prefix the speaker name so reviewers can tell streams apart.
            let cue = "\(i + 1)\n\(ts)\n\(label): \(seg.text)\n"
            blocks.append(cue)
        }
        return blocks.joined(separator: "\n")
    }

    static func writeSRT(_ transcript: MergedTranscript, to url: URL) throws {
        let srt = renderSRT(transcript)
        try srt.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Time formatting

    /// hh:mm:ss for human-readable headers.
    static func timestamp(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        return String(format: "%02d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
    }

    /// hh:mm:ss,mmm for SRT (note the comma — that's spec).
    static func srtTimestamp(_ seconds: TimeInterval) -> String {
        let clamped = max(0, seconds)
        let totalMs = Int((clamped * 1000).rounded())
        let h = totalMs / 3_600_000
        let m = (totalMs / 60_000) % 60
        let s = (totalMs / 1000) % 60
        let ms = totalMs % 1000
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }
}
