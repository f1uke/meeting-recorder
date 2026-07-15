import Foundation

/// Pure, testable logic that turns the free-form text Claude's CLI
/// returns into a strict `Summary`. Deliberately kept out of
/// `ClaudeCLIProvider` (which shells out and can't be unit-tested) so the
/// extraction + decoding path — the part that actually breaks when the
/// model drifts — can be exercised directly against fixtures.
///
/// Why it exists: when Claude runs tools mid-generation (fetching Jira /
/// Confluence references), its final `result` text tends to prefix the
/// JSON with a narration line ("Now I'll compose the structured JSON.")
/// and wrap the object in a ```json fence. Naive `JSONDecoder` on that
/// blob fails. This parser tolerates surrounding prose and fences by
/// pulling the first balanced JSON object out of the text.
enum SummaryResponseParser {
    /// Pull the first balanced JSON object out of a possibly-messy LLM
    /// response. Tolerates a leading narration sentence, a ```json / ```
    /// code fence, and trailing prose — none of those contain a brace, so
    /// scanning from the first `{` to its matching `}` isolates the object.
    ///
    /// The brace scan is string-aware: braces and escaped quotes *inside*
    /// a JSON string value don't affect nesting depth. Returns nil when
    /// there's no `{` or the object never closes (e.g. truncated output).
    static func extractJSONObject(from text: String) -> String? {
        let chars = Array(text)
        guard let start = chars.firstIndex(of: "{") else { return nil }

        var depth = 0
        var inString = false
        var escaped = false
        var i = start
        while i < chars.count {
            let c = chars[i]
            if escaped {
                escaped = false
            } else if inString {
                if c == "\\" {
                    escaped = true
                } else if c == "\"" {
                    inString = false
                }
            } else {
                switch c {
                case "\"": inString = true
                case "{": depth += 1
                case "}":
                    depth -= 1
                    if depth == 0 {
                        return String(chars[start...i])
                    }
                default: break
                }
            }
            i += 1
        }
        return nil  // never balanced — truncated / malformed
    }

    /// Decode a raw LLM response into a `Summary`. Extracts the JSON
    /// object first (tolerating fences / prose), then decodes the strict
    /// wire shape. Throws `LLMError.decodeFailed` carrying a raw excerpt
    /// when the text has no decodable object, so the UI can show what the
    /// model actually said.
    static func decodeSummary(from text: String, providerName: String, generatedAt: Date) throws -> Summary {
        guard let json = extractJSONObject(from: text),
              let data = json.data(using: .utf8) else {
            throw LLMError.decodeFailed(
                "Expected a JSON object {tldr, summary, goals[], keyDecisions[], actionItems[], discussionTopics[]}; none found in the response.\n\nRaw:\n\(excerpt(of: text))"
            )
        }

        let wire: Wire
        do {
            wire = try JSONDecoder().decode(Wire.self, from: data)
        } catch {
            throw LLMError.decodeFailed(
                "Expected JSON {tldr, summary, goals[], keyDecisions[], actionItems[], discussionTopics[]}: \(error.localizedDescription)\n\nRaw:\n\(excerpt(of: json))"
            )
        }

        return wire.toSummary(providerName: providerName, generatedAt: generatedAt)
    }

    /// First ~800 chars, trimmed — enough for the failure UI to show what
    /// the model returned without dumping a multi-KB blob.
    private static func excerpt(of text: String) -> String {
        String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(800))
    }

    // MARK: - Wire shape

    /// Strict JSON contract the summary prompt asks Claude to emit. Kept
    /// here (rather than nested in the provider) so both decoding and the
    /// Summary mapping live next to the parser that produces them.
    struct Wire: Codable {
        let tldr: String?
        let summary: String
        let goals: [String]?
        let keyDecisions: [String]?
        let actionItems: [WireItem]
        let discussionTopics: [WireTopic]?
        let references: [WireRef]?

        func toSummary(providerName: String, generatedAt: Date) -> Summary {
            Summary(
                summary: summary,
                actionItems: actionItems.map {
                    ActionItem(speaker: $0.speaker, text: $0.text, timestamp: $0.timestamp)
                },
                generatedAt: generatedAt,
                providerName: providerName,
                tldr: tldr?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank,
                goals: goals?.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty },
                keyDecisions: keyDecisions?.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty },
                discussionTopics: discussionTopics?.map {
                    DiscussionTopic(heading: $0.heading, bullets: $0.bullets)
                },
                references: references?.compactMap { ref in
                    let label = ref.label.trimmingCharacters(in: .whitespacesAndNewlines)
                    let url = ref.url.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !label.isEmpty, !url.isEmpty else { return nil }
                    return Reference(
                        url: url,
                        label: label,
                        note: ref.note?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
                    )
                }
            )
        }
    }

    struct WireItem: Codable {
        let speaker: String
        let text: String
        let timestamp: String
    }
    struct WireTopic: Codable {
        let heading: String
        let bullets: [String]
    }
    struct WireRef: Codable {
        let url: String
        let label: String
        let note: String?
    }
}

private extension String {
    var nilIfBlank: String? { isEmpty ? nil : self }
}
