import Foundation

/// Pipes the meeting's markdown transcript through `claude -p` (Claude
/// Code CLI's headless mode) and parses the JSON response into a Summary.
///
/// The CLI is shelled out via `Process` so we get the user's existing
/// Claude Code authentication for free — no API key handling in our app.
/// `which claude` is run once at init so the UI can disable the
/// "Generate Summary" button if Claude Code isn't installed.
actor ClaudeCLIProvider: LLMProvider {
    nonisolated let name = "Claude CLI"
    private let claudePath: URL?

    init() {
        self.claudePath = Self.resolveClaudeBinary()
    }

    func availability() async -> LLMAvailability {
        if claudePath == nil {
            return .missingBinary("Install: `npm i -g @anthropic-ai/claude-code`")
        }
        return .available
    }

    func generateSummary(context: MeetingLLMContext) async throws -> Summary {
        guard let claudePath else {
            throw LLMError.notInstalled("which claude returned nothing")
        }

        let prompt = Self.buildPrompt(context: context)
        let raw = try await Self.runClaude(
            at: claudePath,
            input: prompt,
            workingDirectory: context.meetingFolder
        )
        let inner = try Self.parseClaudeOutput(raw)
        let llmJSON = Self.stripJSONFences(inner)

        struct Wire: Codable {
            let tldr: String?
            let summary: String
            let keyDecisions: [String]?
            let actionItems: [WireItem]
            let discussionTopics: [WireTopic]?
            let references: [WireRef]?
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

        guard let data = llmJSON.data(using: .utf8) else {
            throw LLMError.decodeFailed("not utf-8")
        }
        let wire: Wire
        do {
            wire = try JSONDecoder().decode(Wire.self, from: data)
        } catch {
            throw LLMError.decodeFailed(
                "Expected JSON {tldr, summary, keyDecisions[], actionItems[], discussionTopics[]}: \(error.localizedDescription)\n\nRaw:\n\(llmJSON.prefix(800))"
            )
        }

        return Summary(
            summary: wire.summary,
            actionItems: wire.actionItems.map { item in
                ActionItem(speaker: item.speaker, text: item.text, timestamp: item.timestamp)
            },
            generatedAt: Date(),
            providerName: name,
            tldr: wire.tldr?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            keyDecisions: wire.keyDecisions?.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty },
            discussionTopics: wire.discussionTopics?.map {
                DiscussionTopic(heading: $0.heading, bullets: $0.bullets)
            },
            references: wire.references?.compactMap { ref in
                let label = ref.label.trimmingCharacters(in: .whitespacesAndNewlines)
                let url = ref.url.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !label.isEmpty, !url.isEmpty else { return nil }
                return Reference(
                    url: url,
                    label: label,
                    note: ref.note?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                )
            }
        )
    }

    // MARK: - Helpers

    private static func resolveClaudeBinary() -> URL? {
        // Spawn the user's actual login shell *interactively* (`-ilc`).
        // `/bin/sh -lc` only sources `~/.profile` — it misses `~/.zshrc`,
        // which is where most users add `~/.local/bin`, `~/.npm-global/bin`,
        // nvm shims, etc. From a GUI-launched app the env is clean, so
        // those PATH additions never make it in unless we ask zsh (or
        // whichever $SHELL) to run interactively.
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-ilc", "command -v claude"]
        let pipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = pipe
        process.standardError = errPipe
        if (try? process.run()) != nil {
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            // Interactive shells may print plugin warnings (gitstatus,
            // p10k, etc.) to stdout before our command runs. Pick the
            // last line that looks like an absolute path.
            let lines = (String(data: data, encoding: .utf8) ?? "")
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            if let path = lines.last(where: { $0.hasPrefix("/") }),
               FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }

        // Fallback: probe well-known install locations directly. Catches
        // users whose shell rc is slow / errors out, and is independent of
        // whatever PATH gymnastics they've set up.
        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/.local/bin/claude",
            "\(home)/.npm-global/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    private static func buildPrompt(context: MeetingLLMContext) -> String {
        let transcript = context.transcript

        // Resolve display names from the speaker profiles when present
        // — these reflect any rename / attendee mapping the user did.
        // Falls back to the transcript's own speaker labels otherwise.
        let nameByID: [SpeakerID: String] = {
            var map = Dictionary(uniqueKeysWithValues: transcript.speakers.map { ($0.id, $0.displayName) })
            for profile in context.speakerProfiles {
                map[profile.id] = profile.displayName
            }
            return map
        }()

        var body = ""
        for seg in transcript.segments {
            let stamp = formatTimestamp(seg.start)
            let name = nameByID[seg.speaker] ?? seg.speaker.rawValue
            body += "[\(stamp)] **\(name)**: \(seg.text)\n\n"
        }

        let metaSection = buildMetaSection(context: context)
        let rosterSection = buildRosterSection(context: context)
        let contextSection = buildContextSection(context: context)

        // Single rich-JSON prompt — drives both the in-app Summary card
        // (Library detail) and the Markdown meeting note that
        // `MeetingNoteRenderer` writes to the user's vault. We render
        // the note locally from this JSON so we never re-pay the input
        // transcript cost on a second call.
        return """
        You are extracting structured insights from a meeting transcript.
        \(metaSection)\(rosterSection)\(contextSection)
        Read the transcript and respond with ONLY a JSON object — no prose,\
         no markdown fences, no explanation. The shape must be:

        {
          "tldr": "One-line summary in the transcript's primary language. ~12-20 words.",
          "summary": "1-2 paragraph plain text summary in the transcript's primary language. Use **bold** to mark 2-4 key phrases.",
          "keyDecisions": [
            "Move Q1 release to Mar 15 to give QA an extra week"
          ],
          "actionItems": [
            {
              "speaker": "Pim",
              "text": "Move Aof from platform to agent track by Mon",
              "timestamp": "14:22"
            }
          ],
          "discussionTopics": [
            {
              "heading": "Q1 Roadmap",
              "bullets": [
                "Customer X needs feature ready by Mar 15",
                "Engineering capacity tight after Tar's leave"
              ]
            }
          ],
          "references": [
            {
              "url": "https://example.atlassian.net/browse/MOBILE-123",
              "label": "MOBILE-123 — Reword onboarding text",
              "note": "In Progress · assignee: Pim · due Mar 15"
            }
          ]
        }

        Rules:
        - Match the transcript's primary language for ALL prose (tldr, summary, decisions, action item text, topic headings, bullets).
        - "tldr" is one short sentence — what the meeting was about + the most important outcome.
        - "summary" is 1-2 paragraphs. Use **bold** for 2-4 key phrases. Plain Markdown allowed (bold, italic, inline code) — no headings, no lists.
        - "keyDecisions" is concrete decisions reached, NOT proposals or open questions. Empty array if none.
        - "actionItems" is concrete commitments / TODOs assigned to a person. Empty array if none. "speaker" matches a display name from the Speakers roster above; use "You" for the user (the one labeled "Me"). "timestamp" is mm:ss or h:mm:ss matching where the commitment was made.
        - "discussionTopics" is 3-6 topical sections grouping related points across the meeting, NOT a chronological replay. Each topic has a short heading and 2-5 bullets. Bullets are plain text (Markdown bold/italic OK), no nested lists. Empty array only if the meeting was too short to warrant topical grouping.
        - "references" is the resolved metadata for any [JIRA card] URLs in the captured context (see the rule under that section for fetch + shape). Empty array if none were tagged or all fetches failed. Do NOT include non-Jira URLs here.
        - Output ONLY the JSON object. No fences, no preamble.

        Transcript:

        \(body)
        """
    }

    /// Calendar metadata block — gives Claude the meeting's purpose
    /// before it sees the transcript so the summary frames things
    /// correctly (e.g. a 1:1 vs a team standup vs a customer call).
    /// Omitted entirely when there's no attached calendar event.
    private static func buildMetaSection(context: MeetingLLMContext) -> String {
        guard let event = context.calendarEvent else { return "" }
        var lines: [String] = []
        lines.append("Meeting: \(event.title)")
        if let location = event.location, !location.isEmpty {
            lines.append("Location: \(location)")
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        lines.append("When: \(f.string(from: event.startDate))")
        return "\n\n" + lines.joined(separator: "\n")
    }

    /// Captured-context section — feeds Claude the clipboard text /
    /// browser URLs / image filenames the user picked up during the
    /// meeting so the summary can quote a pasted snippet, follow up on
    /// "as mentioned in <link>", or attribute decisions to material
    /// outside the audio. Each item is timestamped against the
    /// recording so the model can correlate it with the transcript.
    /// Omitted entirely when there are no items.
    ///
    /// Image filenames are emitted as relative paths
    /// (`clipboard/<filename>.png`) and the working directory of the
    /// `claude` subprocess is set to the meeting folder, so Claude's
    /// Read tool can fetch the image bytes — the prompt rule below makes
    /// reading every captured image mandatory.
    ///
    /// URLs that look like Jira cards or Confluence pages are tagged
    /// `[JIRA card]` / `[Confluence page]` so the prompt rules can target
    /// them — the model is instructed to fetch every one (Atlassian MCP >
    /// WebFetch) and emit an entry in the `references` JSON field. The
    /// renderer uses that to upgrade the References section's bare URL
    /// into "KEY-123 — Title · Status" or the Confluence page title.
    private static func buildContextSection(context: MeetingLLMContext) -> String {
        guard !context.contextItems.isEmpty else { return "" }
        var lines: [String] = ["Captured during the meeting (clipboard + visited links):"]
        var hasImages = false
        var hasJira = false
        var hasConfluence = false
        for item in context.contextItems {
            let stamp = formatTimestamp(item.offset)
            switch item.kind {
            case .text:
                let snippet = (item.text ?? "")
                    .replacingOccurrences(of: "\n", with: " ")
                let trimmed = snippet.count > 240
                    ? String(snippet.prefix(240)) + "…"
                    : snippet
                lines.append("- [\(stamp)] copied text: \"\(trimmed)\"")
            case .url:
                let urlString = item.text ?? ""
                let isJira = isJiraURL(urlString)
                let isConfluence = isConfluenceURL(urlString)
                if isJira { hasJira = true }
                if isConfluence { hasConfluence = true }
                let label: String = {
                    if isJira { return "[JIRA card]" }
                    if isConfluence { return "[Confluence page]" }
                    if item.source == .browser {
                        if let title = item.pageTitle, !title.isEmpty {
                            return "visited \"\(title)\""
                        }
                        return "visited"
                    }
                    return "copied link"
                }()
                lines.append("- [\(stamp)] \(label): \(urlString)")
            case .image:
                hasImages = true
                if let filename = item.imageFilename {
                    lines.append("- [\(stamp)] copied image: clipboard/\(filename)")
                } else {
                    lines.append("- [\(stamp)] copied image")
                }
            }
        }
        if hasImages {
            lines.append("")
            lines.append("Image files are at the listed relative paths from your working directory. You MUST Read every one of them before writing the summary so visual context informs the result.")
        }
        if hasJira {
            lines.append("")
            lines.append("For every item tagged [JIRA card] you MUST fetch the issue using your Atlassian MCP tool (preferred) or WebFetch as a fallback — do not skip any — then emit one object in `references` with `url` (the original URL verbatim), `label` (e.g. \"MOBILE-123 — Reword onboarding text\"), and `note` (one short line, e.g. \"In Progress · assignee: Pim · due Mar 15\"). If a fetch genuinely fails after retrying, skip that entry rather than guessing.")
        }
        if hasConfluence {
            lines.append("")
            lines.append("For every item tagged [Confluence page] you MUST fetch the page content using your Atlassian MCP tool (preferred) or WebFetch as a fallback — do not skip any — then emit one object in `references` with `url` (the original URL verbatim), `label` (the page title), and `note` (one short line summarizing what the page is, e.g. \"Sprint Retro 2026-10 board\"). Use the page body to ground anything in the summary that refers to it. If a fetch genuinely fails after retrying, skip that entry rather than guessing.")
        }
        return "\n\n" + lines.joined(separator: "\n")
    }

    /// Match Atlassian-Cloud Jira card URLs: `https://<tenant>.atlassian.net/browse/PROJ-123`
    /// (with optional query string / fragment). Tight on purpose — we
    /// don't want to mis-flag random `/browse/` paths from non-Jira
    /// sites and waste a tool call.
    private static func isJiraURL(_ s: String) -> Bool {
        guard let url = URL(string: s),
              let host = url.host?.lowercased(),
              host.hasSuffix(".atlassian.net") else { return false }
        let path = url.path
        guard path.hasPrefix("/browse/") else { return false }
        let key = path.dropFirst("/browse/".count)
        let pattern = #"^[A-Z][A-Z0-9_]+-\d+$"#
        return key.range(of: pattern, options: .regularExpression) != nil
    }

    /// Match Atlassian-Cloud Confluence page URLs: anything under
    /// `https://<tenant>.atlassian.net/wiki/...`. Covers both the modern
    /// `/wiki/spaces/<KEY>/pages/<id>/<slug>` shape and the older
    /// `/wiki/display/...` paths, plus shortlinks like `/wiki/x/<id>`.
    private static func isConfluenceURL(_ s: String) -> Bool {
        guard let url = URL(string: s),
              let host = url.host?.lowercased(),
              host.hasSuffix(".atlassian.net") else { return false }
        return url.path.hasPrefix("/wiki/")
    }

    /// Speakers section — pairs each transcript label with the
    /// calendar attendee they were mapped to (when known). Knowing
    /// "Pim" is "Pim Lertpaitoonpan, organizer (chair)" lets Claude
    /// attribute commitments to a real person, weight chair speech
    /// differently when extracting decisions, and use full names in
    /// the summary instead of bare nicknames.
    private static func buildRosterSection(context: MeetingLLMContext) -> String {
        guard !context.speakerProfiles.isEmpty else { return "" }
        var lines: [String] = ["Speakers (transcript label → identity):"]
        for profile in context.speakerProfiles {
            var bits: [String] = []
            if let email = profile.email, !email.isEmpty {
                bits.append(email)
            }
            if let role = profile.role, !role.isEmpty, role != "unknown" {
                bits.append(role)
            }
            if profile.id == .me {
                bits.append("user — the one whose mic is recorded")
            }
            let suffix = bits.isEmpty ? "" : " — " + bits.joined(separator: ", ")
            lines.append("- **\(profile.displayName)**\(suffix)")
        }
        return "\n\n" + lines.joined(separator: "\n")
    }

    private static func runClaude(
        at path: URL,
        input: String,
        workingDirectory: URL
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = path
                process.arguments = ["-p", "--output-format", "json"]
                // Run inside the meeting folder so any file paths in
                // the prompt (e.g. `clipboard/<uuid>.png`) resolve
                // against the meeting's data root. Lets Claude's Read
                // tool fetch image bytes by relative path when it
                // wants visual context for the captured items.
                process.currentDirectoryURL = workingDirectory

                let stdin = Pipe()
                let stdout = Pipe()
                let stderr = Pipe()
                process.standardInput = stdin
                process.standardOutput = stdout
                process.standardError = stderr

                do {
                    try process.run()
                    if let data = input.data(using: .utf8) {
                        try stdin.fileHandleForWriting.write(contentsOf: data)
                    }
                    try stdin.fileHandleForWriting.close()
                } catch {
                    continuation.resume(throwing: LLMError.launchFailed(error.localizedDescription))
                    return
                }
                process.waitUntilExit()

                let outData = stdout.fileHandleForReading.readDataToEndOfFile()
                let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                let outStr = String(data: outData, encoding: .utf8) ?? ""
                let errStr = String(data: errData, encoding: .utf8) ?? ""

                if process.terminationStatus != 0 {
                    continuation.resume(throwing: LLMError.nonZeroExit(
                        process.terminationStatus,
                        errStr.isEmpty ? outStr : errStr
                    ))
                    return
                }
                if outStr.isEmpty {
                    continuation.resume(throwing: LLMError.empty)
                    return
                }
                continuation.resume(returning: outStr)
            }
        }
    }

    /// Claude Code's `--output-format json` returns an envelope like
    /// `{"type":"result","result":"...response text...","is_error":false,...}`.
    /// Pull `result` out; fall back to assuming the whole output is the
    /// response when the envelope shape doesn't match (e.g. older CLI).
    private static func parseClaudeOutput(_ raw: String) throws -> String {
        guard let data = raw.data(using: .utf8) else { return raw }
        if let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let isError = envelope["is_error"] as? Bool, isError,
               let err = envelope["error"] as? String {
                throw LLMError.nonZeroExit(1, err)
            }
            if let result = envelope["result"] as? String {
                return result
            }
            // Streaming JSON variants store under different keys.
            if let content = envelope["content"] as? String {
                return content
            }
        }
        return raw
    }

    /// Some prompts make Claude wrap JSON in ```json fences despite the
    /// instruction not to. Strip them defensively before decoding.
    private static func stripJSONFences(_ s: String) -> String {
        var trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```") {
            // Drop the first line (e.g. ```json) and the trailing fence.
            if let firstNewline = trimmed.firstIndex(of: "\n") {
                trimmed = String(trimmed[trimmed.index(after: firstNewline)...])
            }
            if let lastFence = trimmed.range(of: "```", options: .backwards) {
                trimmed = String(trimmed[..<lastFence.lowerBound])
            }
        }
        return trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func formatTimestamp(_ t: TimeInterval) -> String {
        let total = Int(t)
        let h = total / 3600
        let m = (total / 60) % 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
