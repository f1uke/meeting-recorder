import XCTest
@testable import Meeting

/// Regression coverage for the "Couldn't parse claude output" bug: when
/// Claude does tool calls (fetching Jira/Confluence references), its final
/// `result` text prefixes the JSON with a narration line and wraps it in a
/// ```json fence. The old fence-stripper only fired when the fence was at
/// the very start of the string, so prose-then-fence output failed to decode.
final class SummaryResponseParserTests: XCTestCase {

    private static let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - extractJSONObject

    func test_extract_cleanJSON_returnsSameObject() {
        let input = #"{"summary":"hi","actionItems":[]}"#
        let out = SummaryResponseParser.extractJSONObject(from: input)
        XCTAssertEqual(out, input)
    }

    func test_extract_fencedJSON_stripsFence() {
        let input = """
        ```json
        {"summary":"hi","actionItems":[]}
        ```
        """
        let out = SummaryResponseParser.extractJSONObject(from: input)
        XCTAssertEqual(out, #"{"summary":"hi","actionItems":[]}"#)
    }

    /// The actual failure mode captured from the reported meeting: a
    /// narration sentence, then a ```json fence, then the object.
    func test_extract_leadingProseThenFence_returnsObject() {
        let input = """
        I have the Confluence page content. Now I'll compose the structured JSON.

        ```json
        {"summary":"hi","actionItems":[]}
        ```
        """
        let out = SummaryResponseParser.extractJSONObject(from: input)
        XCTAssertEqual(out, #"{"summary":"hi","actionItems":[]}"#)
    }

    func test_extract_leadingProseNoFence_returnsObject() {
        let input = #"Here is the summary you asked for: {"summary":"hi","actionItems":[]}"#
        let out = SummaryResponseParser.extractJSONObject(from: input)
        XCTAssertEqual(out, #"{"summary":"hi","actionItems":[]}"#)
    }

    func test_extract_trailingProse_returnsObject() {
        let input = #"{"summary":"hi","actionItems":[]}\#n\#nHope this helps!"#
        let out = SummaryResponseParser.extractJSONObject(from: input)
        XCTAssertEqual(out, #"{"summary":"hi","actionItems":[]}"#)
    }

    /// Brace matching must be string-aware: a `}` inside a JSON string
    /// value must not be mistaken for the end of the object.
    func test_extract_bracesInsideStringValue_takesFullObject() {
        let input = #"prefix {"summary":"a } brace and \"quote\" inside","actionItems":[]} suffix"#
        let out = SummaryResponseParser.extractJSONObject(from: input)
        XCTAssertEqual(out, #"{"summary":"a } brace and \"quote\" inside","actionItems":[]}"#)
    }

    func test_extract_noObject_returnsNil() {
        XCTAssertNil(SummaryResponseParser.extractJSONObject(from: "Sorry, I can't help with that."))
    }

    // MARK: - decodeSummary

    func test_decode_fencedWithPreamble_producesSummary() throws {
        let summary = try SummaryResponseParser.decodeSummary(
            from: Self.fencedWithPreambleFixture,
            providerName: "Claude CLI",
            generatedAt: Self.fixedNow
        )
        // Non-ASCII tldr keeps the string-aware brace scan honest on
        // multibyte input (the real bug's content was Thai).
        XCTAssertEqual(summary.tldr, "ทดสอบสรุป")
        XCTAssertEqual(summary.providerName, "Claude CLI")
        XCTAssertEqual(summary.generatedAt, Self.fixedNow)
        XCTAssertEqual(summary.actionItems.count, 1)
        XCTAssertEqual(summary.actionItems.first?.speaker, "Alice")
        XCTAssertEqual(summary.actionItems.first?.timestamp, "14:22")
        XCTAssertEqual(summary.goals, ["Align on the widget shape"])
        XCTAssertEqual(summary.keyDecisions, ["Ship in sprint 11"])
        XCTAssertEqual(summary.discussionTopics?.count, 1)
        XCTAssertEqual(summary.discussionTopics?.first?.heading, "Roadmap")
        XCTAssertEqual(summary.references?.count, 1)
        XCTAssertEqual(summary.references?.first?.label, "PROJ-1 — Example ticket")
    }

    func test_decode_cleanJSON_mapsAllFields() throws {
        let summary = try SummaryResponseParser.decodeSummary(
            from: Self.cleanFixture,
            providerName: "Claude CLI",
            generatedAt: Self.fixedNow
        )
        XCTAssertEqual(summary.summary, "A short summary.")
        XCTAssertEqual(summary.actionItems.count, 2)
        XCTAssertNil(summary.tldr, "empty tldr should normalize to nil")
        XCTAssertEqual(summary.goals, ["Ship the widget"])
    }

    /// Irreparable output must surface as decodeFailed with a raw excerpt so
    /// the UI can show what the model actually said.
    func test_decode_irreparable_throwsDecodeFailedWithExcerpt() {
        let garbage = "I'm not able to summarize this meeting right now, sorry."
        XCTAssertThrowsError(
            try SummaryResponseParser.decodeSummary(from: garbage, providerName: "Claude CLI", generatedAt: Self.fixedNow)
        ) { error in
            guard case let LLMError.decodeFailed(detail) = error else {
                return XCTFail("expected LLMError.decodeFailed, got \(error)")
            }
            XCTAssertTrue(detail.contains("not able to summarize"), "excerpt should include the raw output; got: \(detail)")
        }
    }

    /// A fenced object whose JSON is truncated (model ran out of tokens
    /// mid-object) is still irreparable and must throw, not crash.
    func test_decode_truncatedJSON_throwsDecodeFailed() {
        let truncated = """
        ```json
        {"summary":"hi","actionItems":[{"speaker":"Pim","text":"do
        """
        XCTAssertThrowsError(
            try SummaryResponseParser.decodeSummary(from: truncated, providerName: "Claude CLI", generatedAt: Self.fixedNow)
        ) { error in
            guard case LLMError.decodeFailed = error else {
                return XCTFail("expected LLMError.decodeFailed, got \(error)")
            }
        }
    }

    // MARK: - Fixtures

    // Synthetic stand-in for the exact failure shape captured in the wild:
    // a narration sentence, a ```json fence, then the object. Content is
    // invented placeholder data — the test only exercises the parse path.
    private static let fencedWithPreambleFixture = """
    I have the reference content. Now I'll compose the structured JSON.

    ```json
    {
      "tldr": "ทดสอบสรุป",
      "summary": "A **sample** meeting summary for the parser test.",
      "goals": ["Align on the widget shape"],
      "keyDecisions": ["Ship in sprint 11"],
      "actionItems": [
        {"speaker": "Alice", "text": "Draft the API doc", "timestamp": "14:22"}
      ],
      "discussionTopics": [
        {"heading": "Roadmap", "bullets": ["Feature ready by next release"]}
      ],
      "references": [
        {"url": "https://example.atlassian.net/browse/PROJ-1", "label": "PROJ-1 — Example ticket", "note": "In Progress"}
      ]
    }
    ```
    """

    private static let cleanFixture = #"""
    {
      "tldr": "",
      "summary": "A short summary.",
      "goals": ["Ship the widget"],
      "keyDecisions": [],
      "actionItems": [
        {"speaker": "You", "text": "Send notes", "timestamp": "01:00"},
        {"speaker": "Bob", "text": "Review PR", "timestamp": "02:30"}
      ],
      "discussionTopics": []
    }
    """#
}
