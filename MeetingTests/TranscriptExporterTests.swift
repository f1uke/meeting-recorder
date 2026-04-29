import XCTest
@testable import Meeting

final class TranscriptExporterTests: XCTestCase {
    private func sampleTranscript() -> MergedTranscript {
        MergedTranscript(
            duration: 75.5,
            language: "th",
            providers: ["WhisperKit", "MockMic"],
            segments: [
                TranscriptSegment(
                    start: 5.5, end: 8.0,
                    speaker: .diarized(0),
                    text: "สวัสดีครับ start",
                    source: .meetingOutput
                ),
                TranscriptSegment(
                    start: 10.0, end: 12.0,
                    speaker: .me,
                    text: "ฉันพูดเอง",
                    source: .mic
                ),
                TranscriptSegment(
                    start: 70.123, end: 72.456,
                    speaker: .diarized(1),
                    text: "ปิด meeting",
                    source: .meetingOutput
                )
            ],
            words: nil,
            speakers: [
                Speaker(id: .me, displayName: "ฉัน"),
                Speaker(id: .diarized(0), displayName: "Pim"),
                Speaker(id: .diarized(1), displayName: "Speaker 2")
            ]
        )
    }

    // MARK: - Timestamp formatting

    func test_timestamp_formatsHHMMSS() {
        XCTAssertEqual(TranscriptExporter.timestamp(0), "00:00:00")
        XCTAssertEqual(TranscriptExporter.timestamp(59.9), "00:00:59")
        XCTAssertEqual(TranscriptExporter.timestamp(60), "00:01:00")
        XCTAssertEqual(TranscriptExporter.timestamp(3661), "01:01:01")
    }

    func test_srtTimestamp_includesMillisWithComma() {
        XCTAssertEqual(TranscriptExporter.srtTimestamp(0), "00:00:00,000")
        XCTAssertEqual(TranscriptExporter.srtTimestamp(0.123), "00:00:00,123")
        XCTAssertEqual(TranscriptExporter.srtTimestamp(70.123), "00:01:10,123")
        XCTAssertEqual(TranscriptExporter.srtTimestamp(3661.456), "01:01:01,456")
    }

    func test_srtTimestamp_clampsNegativeToZero() {
        XCTAssertEqual(TranscriptExporter.srtTimestamp(-1), "00:00:00,000")
    }

    // MARK: - Markdown rendering

    func test_markdown_includesHeaderAndSpeakers() {
        let md = TranscriptExporter.renderMarkdown(sampleTranscript())
        XCTAssertTrue(md.contains("# Meeting transcript"))
        XCTAssertTrue(md.contains("Duration: 00:01:15"))
        XCTAssertTrue(md.contains("Language: th"))
        XCTAssertTrue(md.contains("ฉัน (`me`)"))
        XCTAssertTrue(md.contains("Pim (`speaker_0`)"))
    }

    func test_markdown_rendersSpeakerLabelsForEachSegment() {
        let md = TranscriptExporter.renderMarkdown(sampleTranscript())
        XCTAssertTrue(md.contains("**Pim** [00:00:05 – 00:00:08]"))
        XCTAssertTrue(md.contains("**ฉัน** [00:00:10 – 00:00:12]"))
        XCTAssertTrue(md.contains("**Speaker 2** [00:01:10 – 00:01:12]"))
        XCTAssertTrue(md.contains("สวัสดีครับ start"))
        XCTAssertTrue(md.contains("ฉันพูดเอง"))
    }

    // MARK: - SRT rendering

    func test_srt_hasSequentialNumberedCues() {
        let srt = TranscriptExporter.renderSRT(sampleTranscript())
        let blocks = srt.split(separator: "\n\n", omittingEmptySubsequences: true)
        XCTAssertEqual(blocks.count, 3)
        XCTAssertTrue(srt.hasPrefix("1\n"))
        XCTAssertTrue(srt.contains("\n2\n"))
        XCTAssertTrue(srt.contains("\n3\n"))
    }

    func test_srt_includesSpeakerLabelInCue() {
        let srt = TranscriptExporter.renderSRT(sampleTranscript())
        XCTAssertTrue(srt.contains("Pim: สวัสดีครับ start"))
        XCTAssertTrue(srt.contains("ฉัน: ฉันพูดเอง"))
        XCTAssertTrue(srt.contains("Speaker 2: ปิด meeting"))
    }

    func test_srt_usesCommaMillisecondsTimecode() {
        let srt = TranscriptExporter.renderSRT(sampleTranscript())
        XCTAssertTrue(srt.contains("00:00:05,500 --> 00:00:08,000"))
        XCTAssertTrue(srt.contains("00:01:10,123 --> 00:01:12,456"))
    }

    // MARK: - File writing

    func test_writeAll_producesAllThreeFiles() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        try TranscriptExporter.writeAll(sampleTranscript(), in: folder)

        for name in ["transcript.json", "transcript.md", "transcript.srt"] {
            let url = folder.appendingPathComponent(name)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                          "missing: \(name)")
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            XCTAssertGreaterThan((attrs[.size] as? Int) ?? 0, 0, "empty: \(name)")
        }
    }

    func test_writeJSON_isRoundTrippable() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let original = sampleTranscript()
        let url = folder.appendingPathComponent("t.json")
        try TranscriptExporter.writeJSON(original, to: url)

        let data = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode(MergedTranscript.self, from: data)

        XCTAssertEqual(decoded.duration, original.duration)
        XCTAssertEqual(decoded.segments.count, original.segments.count)
        XCTAssertEqual(decoded.speakers.map(\.displayName),
                       original.speakers.map(\.displayName))
    }
}
