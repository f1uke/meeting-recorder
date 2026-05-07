import Foundation
import WhisperKit
import SpeakerKit

/// Cloud transcription via Google's Gemini API.
///
/// Flow:
/// 1. Upload the audio file to Gemini's Files API (resumable upload).
/// 2. Wait for processing (`ACTIVE` state).
/// 3. Call `generateContent` with the file reference + a structured-output
///    schema asking for `{segments: [{start, end, text}]}`. System
///    instruction primes the model with the user's tech glossary so
///    English domain terms survive Thai-leaning transcription.
/// 4. For mic streams (`knownSpeaker = .me`, no diarization): map directly.
/// 5. For meeting output (`withDiarization = true`): run **local SpeakerKit**
///    on the audio to get a speaker timeline, then merge via
///    `DiarizationMerger` so audio embeddings never leave the device.
///
/// API key lives in `AppPreferences.shared.geminiAPIKey` (UserDefaults for
/// now — TODO migrate to Keychain).
actor GeminiProvider: TranscriptionProvider {
    nonisolated let name: String

    private let apiKey: String
    private let glossary: String
    private let modelName: String
    private let useBatchAPI: Bool

    private let urlSession: URLSession

    private var diarizerBox: DiarizerBox?
    private var diarizerLoadTask: Task<DiarizerBox, Error>?

    init(
        apiKey: String,
        glossary: String,
        modelName: String = "gemini-2.5-flash",
        useBatchAPI: Bool = false
    ) {
        self.apiKey = apiKey
        self.glossary = glossary
        self.modelName = modelName
        self.useBatchAPI = useBatchAPI
        let suffix = useBatchAPI ? " (batch)" : ""
        self.name = "Gemini (\(modelName))\(suffix) + SpeakerKit"

        let config = URLSessionConfiguration.default
        // Long uploads + long generateContent calls. The default 60s timeout
        // routinely fails on hour-long meetings.
        config.timeoutIntervalForRequest = 600
        config.timeoutIntervalForResource = 1800
        self.urlSession = URLSession(configuration: config)
    }

    func unloadModels() {
        diarizerBox = nil
    }

    func transcribe(
        audioURL: URL,
        options: TranscriptionOptions,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> TranscriptResult {
        guard !apiKey.isEmpty else {
            throw TranscriptionError.modelLoadFailed(
                "Gemini API key not set. Open Settings → Transcription and paste your key."
            )
        }
        guard FileManager.default.fileExists(atPath: audioURL.path(percentEncoded: false)) else {
            throw TranscriptionError.audioMissing(audioURL)
        }

        // Generate band: how much of total progress is owned by upload+
        // generateContent (the rest is diarization, when applicable).
        let generateEnd = options.withDiarization ? 0.70 : 1.0
        progress?(0)

        // Chunk the audio at 60 s boundaries before sending to Gemini.
        // Without chunking, LLM-based transcription drifts on long audio
        // and 2.5 Pro's extended thinking inflates the per-chunk token
        // budget (see `thinkingBudget` in `runGenerateContent`). 60 s
        // keeps every chunk well inside the tight-attention window and
        // cleanly under the combined-thinking+output token ceiling. We
        // tried 90 s on Pro for RPD savings but it tripped MAX_TOKENS
        // truncation on dense Thai content. Mic preprocessing (AEC /
        // normalize / mute gate) is folded into chunk preparation since
        // both need the float array.
        let chunks = try CloudAudioPrep.prepareChunks(
            audioURL: audioURL,
            options: options,
            tempPrefix: "gemini",
            chunkDuration: 60,
            providerName: name,
            logTag: "Gemini"
        )
        defer {
            for chunk in chunks where chunk.isTemp {
                try? FileManager.default.removeItem(at: chunk.url)
            }
        }

        // Batch path replaces the parallel-sync chunk fan-out with a single
        // batch job that processes every chunk server-side. Half the cost,
        // looser latency. The synchronous path below is the original code
        // and stays the default.
        let allCloudSegments: [CloudSegment]
        if useBatchAPI {
            allCloudSegments = try await transcribeViaBatch(
                chunks: chunks,
                language: options.language
            ) { fraction in
                progress?(fraction * generateEnd)
            }
            progress?(generateEnd)
        } else {
            allCloudSegments = try await transcribeViaSync(
                chunks: chunks,
                language: options.language,
                generateEnd: generateEnd,
                progress: progress
            )
        }

        // Diarize (or assign known speaker) and produce final result.
        // Diarization runs once on the original audioURL — chunking the
        // diarizer would fragment speaker IDs across chunks (each call
        // assigns labels independently), so the input must stay whole.
        let cloudSegments = allCloudSegments
        let totalDuration = cloudSegments.last.map { TimeInterval($0.end) } ?? 0
        let language = cloudSegments.first?.language ?? options.language

        if options.withDiarization {
            let timeline = try await runDiarization(
                audioURL: audioURL,
                expectedSpeakerCount: options.expectedSpeakerCount
            ) { fraction in
                progress?(generateEnd + fraction * (1.0 - generateEnd))
            }
            let merged = DiarizationMerger.merge(
                textSegments: cloudSegments.map {
                    DiarizationMerger.TextSegment(start: $0.start, end: $0.end, text: $0.text)
                },
                speakerTimeline: timeline,
                source: options.source
            )
            progress?(1.0)
            return TranscriptResult(
                provider: name,
                model: modelName,
                language: language,
                duration: totalDuration,
                segments: merged
            )
        }

        // Mic / known-speaker path: every segment is the supplied speaker.
        let speaker = options.knownSpeaker ?? SpeakerID.me
        let segments: [TranscriptSegment] = cloudSegments.compactMap { seg in
            let trimmed = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let dur = seg.end - seg.start
            if HallucinationFilter.isHallucination(text: trimmed, durationSeconds: dur) {
                return nil
            }
            return TranscriptSegment(
                start: seg.start,
                end: seg.end,
                speaker: speaker,
                text: trimmed,
                source: options.source
            )
        }
        progress?(1.0)
        return TranscriptResult(
            provider: name,
            model: modelName,
            language: language,
            duration: totalDuration,
            segments: segments
        )
    }

    // MARK: - Sync path (parallel chunk fan-out)

    private func transcribeViaSync(
        chunks: [CloudAudioPrep.Chunk],
        language: String?,
        generateEnd: Double,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> [CloudSegment] {
        // Process up to `maxConcurrent` chunks in parallel. Each chunk owns
        // an independent upload → waitActive → generateContent pipeline,
        // so concurrent chunks share nothing but the URLSession (which is
        // built for parallel use). 8 keeps peak burst around 50 RPM —
        // a third of the Tier 1 paid 2.5-Pro RPM ceiling — so retries
        // and other in-flight work have plenty of headroom. Free-tier
        // users on the tight 5 RPM quota should drop this to 1.
        let maxConcurrent = 8
        let aggregator = ChunkProgressAggregator(count: chunks.count) { fraction in
            progress?(fraction * generateEnd)
        }
        let collected = try await withThrowingTaskGroup(of: (Int, [CloudSegment]).self) { group in
            var dispatched = 0
            // Seed the initial wave.
            while dispatched < min(maxConcurrent, chunks.count) {
                let idx = dispatched
                let chunk = chunks[idx]
                group.addTask { [self] in
                    let segs = try await transcribeOneChunk(
                        audioURL: chunk.url,
                        offset: chunk.offset,
                        language: language,
                        onProgress: { fraction in
                            aggregator.update(index: idx, fraction: fraction)
                        }
                    )
                    return (idx, segs)
                }
                dispatched += 1
            }
            // Drain + refill: as each chunk lands, dispatch the next one
            // until every chunk has been queued.
            var results: [(Int, [CloudSegment])] = []
            results.reserveCapacity(chunks.count)
            while let result = try await group.next() {
                results.append(result)
                if dispatched < chunks.count {
                    let idx = dispatched
                    let chunk = chunks[idx]
                    group.addTask { [self] in
                        let segs = try await transcribeOneChunk(
                            audioURL: chunk.url,
                            offset: chunk.offset,
                            language: language,
                            onProgress: { fraction in
                                aggregator.update(index: idx, fraction: fraction)
                            }
                        )
                        return (idx, segs)
                    }
                    dispatched += 1
                }
            }
            return results
        }
        // Restore source-audio chronological order — TaskGroup yields in
        // completion order, but downstream merging assumes sorted segments.
        progress?(generateEnd)
        return collected
            .sorted { $0.0 < $1.0 }
            .flatMap { $0.1 }
    }

    // MARK: - Per-chunk pipeline

    /// Run the full upload → wait-active → generateContent pipeline for a
    /// single chunk. Reports its own 0...1 progress; the caller maps that
    /// into the appropriate band of the overall progress bar. Returns
    /// chunk segments with the chunk's offset already baked into start/end.
    private nonisolated func transcribeOneChunk(
        audioURL: URL,
        offset: TimeInterval,
        language: String?,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> [CloudSegment] {
        // Within-chunk progress bands.
        let uploadEnd = 0.20
        let processingEnd = 0.30

        onProgress(0)

        let uploaded = try await uploadFile(at: audioURL) { fraction in
            onProgress(fraction * uploadEnd)
        }
        onProgress(uploadEnd)
        // Best-effort delete: Files API stores 48h, paid quota is per-byte
        // so cleaning eagerly keeps a long meeting from accumulating leaked
        // chunks across runs.
        defer {
            Task { [weak self] in
                guard let self else { return }
                try? await self.deleteFile(name: uploaded.name)
            }
        }

        try await waitUntilActive(name: uploaded.name)
        onProgress(processingEnd)

        let raw = try await runGenerateContent(
            fileURI: uploaded.uri,
            mimeType: uploaded.mimeType,
            language: language
        )
        onProgress(1.0)

        return raw.map { seg in
            CloudSegment(
                start: seg.start + offset,
                end: seg.end + offset,
                text: seg.text,
                language: seg.language
            )
        }
    }

    // MARK: - Retry

    /// Run an HTTP call with exponential backoff for transient failures.
    /// Retries on 5xx, 429, and network-level errors (timeout, connection
    /// lost, DNS). 4xx responses (except 429) and decode errors propagate
    /// immediately — they're caller bugs, not transient.
    ///
    /// Backoff: 2s, 6s, 18s. Tuned around Gemini's typical 503 windows
    /// (a few seconds of overload that clear quickly).
    private nonisolated func sendWithRetry(
        label: String,
        maxAttempts: Int = 4,
        _ send: () async throws -> (Data, URLResponse)
    ) async throws -> (Data, URLResponse) {
        var attempt = 0
        while true {
            attempt += 1
            do {
                let (data, response) = try await send()
                if let http = response as? HTTPURLResponse,
                   shouldRetryStatus(http.statusCode),
                   attempt < maxAttempts {
                    let summary = Self.explainGeminiError(status: http.statusCode, body: data)
                    let delay = retryDelay(attempt: attempt)
                    NSLog("[Meeting/Transcribe] Gemini %@: %@, retrying in %.1fs (attempt %d/%d)",
                          label, summary, delay, attempt, maxAttempts)
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }
                return (data, response)
            } catch {
                if attempt < maxAttempts, isRetryableNetworkError(error) {
                    let delay = retryDelay(attempt: attempt)
                    NSLog("[Meeting/Transcribe] Gemini %@: network error, retrying in %.1fs (attempt %d/%d): %@",
                          label, delay, attempt, maxAttempts, error.localizedDescription)
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }
                throw error
            }
        }
    }

    private nonisolated func shouldRetryStatus(_ code: Int) -> Bool {
        // 429 is RESOURCE_EXHAUSTED — usually a daily/per-minute quota
        // ceiling, not transient overload. Retrying eats user time without
        // improving the outcome (the quota window doesn't move on the
        // timescales our backoff covers). Surface immediately so the user
        // can switch models / enable billing instead of waiting.
        (500...599).contains(code)
    }

    /// Decode Gemini's standard `{error: {code, message, status}}` envelope
    /// into a short, user-facing string. Falls back to a truncated raw body
    /// when the shape doesn't match (e.g. the gateway returned HTML).
    private static func explainGeminiError(status: Int, body: Data) -> String {
        struct Envelope: Decodable {
            struct ErrBody: Decodable {
                let code: Int?
                let message: String?
                let status: String?
            }
            let error: ErrBody?
        }
        if let envelope = try? JSONDecoder().decode(Envelope.self, from: body),
           let err = envelope.error {
            let message = err.message ?? "no message"
            if let s = err.status, !s.isEmpty {
                return "\(s) (HTTP \(status)): \(message)"
            }
            return "HTTP \(status): \(message)"
        }
        let raw = String(data: body, encoding: .utf8) ?? ""
        return "HTTP \(status) — \(raw.prefix(300))"
    }

    private nonisolated func retryDelay(attempt: Int) -> Double {
        // 2, 6, 18, 54... — Gemini's overload windows usually clear in <30s
        // so by attempt 3-4 we've waited long enough that further retries
        // are mostly throwing good time after bad.
        2.0 * pow(3.0, Double(attempt - 1))
    }

    private nonisolated func isRetryableNetworkError(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .timedOut, .networkConnectionLost, .cannotConnectToHost,
             .notConnectedToInternet, .dnsLookupFailed, .resourceUnavailable,
             .cannotFindHost, .badServerResponse:
            return true
        default:
            return false
        }
    }

    // MARK: - Files API: upload

    private struct UploadedFile: Sendable {
        let name: String       // e.g. "files/abc123"
        let uri: String        // full URI to reference in generateContent
        let mimeType: String
    }

    /// Resumable upload (2 round trips): metadata POST → bytes upload.
    /// Reports 0...1 progress for the bytes phase. `mimeOverride` forces
    /// a specific MIME (used for JSONL batch input — `mimeType(for:)`
    /// would otherwise fall through to `application/octet-stream`).
    private nonisolated func uploadFile(
        at audioURL: URL,
        mimeOverride: String? = nil,
        onProgress: @Sendable (Double) -> Void
    ) async throws -> UploadedFile {
        let fileSize = try (FileManager.default.attributesOfItem(atPath: audioURL.path(percentEncoded: false))[.size] as? Int) ?? 0
        let mimeType = mimeOverride ?? mimeType(for: audioURL)

        // (1) Initiate resumable upload — Gemini returns the actual byte
        // upload URL in the `x-goog-upload-url` response header.
        var startReq = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/upload/v1beta/files")!)
        startReq.httpMethod = "POST"
        startReq.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        startReq.setValue("resumable", forHTTPHeaderField: "X-Goog-Upload-Protocol")
        startReq.setValue("start", forHTTPHeaderField: "X-Goog-Upload-Command")
        startReq.setValue(String(fileSize), forHTTPHeaderField: "X-Goog-Upload-Header-Content-Length")
        startReq.setValue(mimeType, forHTTPHeaderField: "X-Goog-Upload-Header-Content-Type")
        startReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        startReq.httpBody = #"{"file":{"display_name":"meeting"}}"#.data(using: .utf8)

        let (startBody, startResponse) = try await sendWithRetry(label: "upload-start") {
            try await urlSession.data(for: startReq)
        }
        guard let httpStart = startResponse as? HTTPURLResponse else {
            throw TranscriptionError.providerFailed(name, underlying: GeminiError.uploadFailed("no HTTP response on upload start"))
        }
        guard httpStart.statusCode == 200 else {
            let summary = Self.explainGeminiError(status: httpStart.statusCode, body: startBody)
            throw TranscriptionError.providerFailed(name, underlying: GeminiError.uploadFailed("start — \(summary)"))
        }
        // Header lookup is case-insensitive in HTTPURLResponse.
        guard let uploadURLString = httpStart.value(forHTTPHeaderField: "x-goog-upload-url"),
              let uploadURL = URL(string: uploadURLString) else {
            throw TranscriptionError.providerFailed(name, underlying: GeminiError.uploadFailed("missing x-goog-upload-url header"))
        }

        // (2) Upload bytes + finalize. URLSession upload-from-file streams
        // the data so we don't load 28 MB into memory.
        var byteReq = URLRequest(url: uploadURL)
        byteReq.httpMethod = "POST"
        byteReq.setValue(String(fileSize), forHTTPHeaderField: "Content-Length")
        byteReq.setValue("0", forHTTPHeaderField: "X-Goog-Upload-Offset")
        byteReq.setValue("upload, finalize", forHTTPHeaderField: "X-Goog-Upload-Command")

        // We don't have streaming-progress callbacks via async/await, so
        // emit a single 0.5 mid-update before the call resolves.
        onProgress(0.0)
        // Retrying byte upload is safe: URLSession.upload(fromFile:) opens
        // the file fresh per attempt, no stream-consumption hazard.
        let (data, byteResponse) = try await sendWithRetry(label: "upload-bytes") {
            try await urlSession.upload(for: byteReq, fromFile: audioURL)
        }
        onProgress(1.0)
        guard let httpBytes = byteResponse as? HTTPURLResponse, httpBytes.statusCode == 200 else {
            let status = (byteResponse as? HTTPURLResponse)?.statusCode ?? -1
            let summary = Self.explainGeminiError(status: status, body: data)
            throw TranscriptionError.providerFailed(name, underlying: GeminiError.uploadFailed("bytes — \(summary)"))
        }

        // Response: { "file": { "name": "files/...", "uri": "...", "mimeType": "...", "state": "PROCESSING" } }
        struct Wire: Decodable {
            struct File: Decodable { let name: String; let uri: String; let mimeType: String? }
            let file: File
        }
        let parsed: Wire
        do {
            parsed = try JSONDecoder().decode(Wire.self, from: data)
        } catch {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw TranscriptionError.providerFailed(name, underlying: GeminiError.uploadFailed("decode upload response: \(error.localizedDescription) — \(body.prefix(500))"))
        }
        return UploadedFile(name: parsed.file.name, uri: parsed.file.uri, mimeType: parsed.file.mimeType ?? mimeType)
    }

    /// Poll `GET /v1beta/{name}` until state is ACTIVE, FAILED, or we
    /// time out. Audio files typically reach ACTIVE in 2-10 seconds.
    private nonisolated func waitUntilActive(name: String, timeout: TimeInterval = 120) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/\(name)")!
        struct Wire: Decodable { let state: String? }

        while Date() < deadline {
            var req = URLRequest(url: url)
            req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
            let (data, response) = try await urlSession.data(for: req)
            if let http = response as? HTTPURLResponse, http.statusCode == 200,
               let parsed = try? JSONDecoder().decode(Wire.self, from: data) {
                switch parsed.state {
                case "ACTIVE": return
                case "FAILED":
                    throw TranscriptionError.providerFailed(self.name, underlying: GeminiError.fileProcessingFailed)
                default: break  // PROCESSING → keep polling
                }
            }
            // 60s-chunk WAVs typically reach ACTIVE in 1-3s; polling at
            // 500ms keeps total wait close to actual processing latency
            // without spamming the API (peak 2 req/s per concurrent chunk).
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw TranscriptionError.providerFailed(self.name, underlying: GeminiError.fileProcessingTimeout)
    }

    private nonisolated func deleteFile(name: String) async throws {
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/\(name)")!
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        _ = try await urlSession.data(for: req)
    }

    // MARK: - generateContent

    private struct CloudSegment: Sendable {
        let start: TimeInterval
        let end: TimeInterval
        let text: String
        let language: String?
    }

    /// Build the per-chunk `generateContent`-shaped request dictionary.
    /// Used by both the synchronous path (sent as the full HTTP body) and
    /// the batch path (one of these per line in the JSONL input file).
    private nonisolated func makeGenerateRequestBody(
        fileURI: String,
        mimeType: String,
        language: String?
    ) -> [String: Any] {
        let systemText = systemInstruction(language: language)
        let userText = "Transcribe the attached audio. Output JSON matching the schema. Each segment is one continuous utterance, typically 5-15 seconds. Timestamps are in seconds (decimal), measured from the start of the audio."

        // responseSchema (TYPE-CAPS form) is the most broadly-supported
        // structured-output shape on 2.5-flash. Number/string vocab matches
        // the OpenAPI subset Gemini accepts.
        return [
            "systemInstruction": ["parts": [["text": systemText]]],
            "contents": [
                ["parts": [
                    ["text": userText],
                    ["file_data": ["mime_type": mimeType, "file_uri": fileURI]],
                ]]
            ],
            "generationConfig": [
                "responseMimeType": "application/json",
                "temperature": 0.0,
                // Default is 8192, which truncates structured-output JSON on
                // long meetings — the model gets cut off mid-segment and the
                // truncated JSON fails to decode. 65535 is the max for the
                // 2.5 family and covers ~2-3 hours of conversational audio.
                "maxOutputTokens": 65535,
                // 2.5 Pro has extended thinking on by default and the
                // thinking tokens count against `maxOutputTokens`. On
                // dense Thai chunks Pro consumed nearly the entire 65k
                // budget on internal reasoning and the actual JSON
                // output got truncated → MAX_TOKENS finishReason. Cap
                // thinking at 128 (the minimum Pro accepts; 0 disables
                // thinking entirely on 2.5 Flash but Pro requires ≥128)
                // so the structured output gets the full headroom it
                // needs. Transcription is not a reasoning task — we
                // don't need the model deliberating.
                "thinkingConfig": [
                    "thinkingBudget": 128
                ],
                "responseSchema": [
                    "type": "OBJECT",
                    "properties": [
                        "language": ["type": "STRING"],
                        "segments": [
                            "type": "ARRAY",
                            "items": [
                                "type": "OBJECT",
                                "properties": [
                                    "start": ["type": "NUMBER"],
                                    "end": ["type": "NUMBER"],
                                    "text": ["type": "STRING"],
                                ],
                                "required": ["start", "end", "text"],
                            ],
                        ],
                    ],
                    "required": ["language", "segments"],
                ],
            ],
        ]
    }

    private nonisolated func runGenerateContent(
        fileURI: String,
        mimeType: String,
        language: String?
    ) async throws -> [CloudSegment] {
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(modelName):generateContent")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = makeGenerateRequestBody(fileURI: fileURI, mimeType: mimeType, language: language)
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let (data, response) = try await sendWithRetry(label: "generateContent") {
            try await urlSession.data(for: req)
        }
        guard let http = response as? HTTPURLResponse else {
            throw TranscriptionError.providerFailed(name, underlying: GeminiError.generateFailed("no HTTP response"))
        }
        guard http.statusCode == 200 else {
            let summary = Self.explainGeminiError(status: http.statusCode, body: data)
            throw TranscriptionError.providerFailed(name, underlying: GeminiError.generateFailed(summary))
        }
        return try parseSegmentsFromEnvelope(envelopeData: data)
    }

    /// Decode a `GenerateContentResponse` envelope into `CloudSegment`s.
    /// The envelope shape is the same whether it came back from a sync
    /// `generateContent` call or as one entry inside a batch results JSONL,
    /// so both paths share this parser.
    private nonisolated func parseSegmentsFromEnvelope(envelopeData: Data) throws -> [CloudSegment] {
        // Envelope: { candidates: [{ content: { parts: [{ text: "<json string>" }] }, finishReason }] }
        struct Envelope: Decodable {
            struct Candidate: Decodable {
                struct Content: Decodable {
                    struct Part: Decodable { let text: String? }
                    let parts: [Part]?
                }
                let content: Content?
                let finishReason: String?
            }
            let candidates: [Candidate]?
        }
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: envelopeData)
        } catch {
            let body = String(data: envelopeData, encoding: .utf8) ?? ""
            throw TranscriptionError.providerFailed(name, underlying: GeminiError.generateFailed("decode envelope: \(error.localizedDescription) — \(body.prefix(500))"))
        }
        let candidate = envelope.candidates?.first
        let finishReason = candidate?.finishReason
        // MAX_TOKENS = the model ran out of output tokens mid-JSON. Surface
        // it explicitly so the user knows to switch to a smaller meeting
        // chunk or a model with more headroom — generic "decode failed" is
        // misleading when the underlying issue is truncation.
        if finishReason == "MAX_TOKENS" {
            throw TranscriptionError.providerFailed(name, underlying: GeminiError.generateFailed(
                "Output truncated at maxOutputTokens. Try a shorter audio file, or switch to Gemini 2.5 Flash / Pro (more output headroom than Flash Lite)."
            ))
        }
        guard let inner = candidate?.content?.parts?.first?.text,
              let innerData = inner.data(using: .utf8) else {
            throw TranscriptionError.providerFailed(name, underlying: GeminiError.generateFailed(
                "Empty candidate text (finishReason=\(finishReason ?? "nil"))"
            ))
        }

        struct InnerWire: Decodable {
            struct Seg: Decodable { let start: Double; let end: Double; let text: String }
            let language: String?
            let segments: [Seg]
        }
        let parsed: InnerWire
        do {
            parsed = try JSONDecoder().decode(InnerWire.self, from: innerData)
        } catch {
            // Dump the full payload to Console so we can see the actual
            // shape — popover truncates; .prefix(500) in the error doesn't
            // show enough to debug bad models / hallucinated formats.
            NSLog("[Meeting/Transcribe] Gemini inner JSON decode failed (finishReason=%@):\n%@",
                  finishReason ?? "nil", inner)
            throw TranscriptionError.providerFailed(name, underlying: GeminiError.generateFailed(
                "decode inner JSON: \(error.localizedDescription). Full payload dumped to Console (filter [Meeting/Transcribe])."
            ))
        }
        return parsed.segments.map {
            CloudSegment(start: $0.start, end: $0.end, text: $0.text, language: parsed.language)
        }
    }

    private nonisolated func systemInstruction(language: String?) -> String {
        let langHint: String
        switch language {
        case "th": langHint = "The audio is primarily Thai with frequent inline English technical terms."
        case "en": langHint = "The audio is primarily English."
        case nil:  langHint = "The audio may mix Thai and English (code-switching)."
        case .some(let other): langHint = "The audio is primarily \(other), possibly mixed with English technical terms."
        }
        return """
        You transcribe meeting audio for an iOS/Android mobile development team at Finnomena.
        \(langHint)

        Rules:
        - Transcribe verbatim. Do not paraphrase or summarize.
        - Preserve English technical terms in English. Do NOT romanize, translate, or transliterate them.
        - Keep speakers' filler words and incomplete sentences.
        - Use Thai script for Thai speech and Latin script for English. Mixed within one segment is fine.
        - Output only the JSON specified by the schema. No prose, no markdown fences.

        Domain glossary (recognize these as English even when surrounding speech is Thai):
        \(glossary)
        """
    }

    // MARK: - Multi-stream batch override
    //
    // When `useBatchAPI` is on, we override `transcribeBatch` so the
    // queue's mic + output streams pool into a single Gemini batch. One
    // upload phase, one batch submit, one poll. Halves wall-clock vs.
    // running two sequential batches.
    //
    // When `useBatchAPI` is off, we fall through to per-stream calls of
    // `transcribe(...)` (which uses the parallel sync path internally).
    // The protocol's default extension does the same thing — we override
    // explicitly anyway so the behavior is obvious from this file.

    func transcribeBatch(
        streams: [TranscribeStream],
        progress: (@Sendable (Double) -> Void)?,
        status: (@Sendable (TranscriptionSession.StageStatus) -> Void)?
    ) async throws -> [URL: TranscriptResult] {
        guard useBatchAPI else {
            // Sync mode — sequential per stream. Same shape as the protocol
            // extension default but keeps everything in one place. No
            // useful status to emit; the slow path is the batch poll loop.
            var results: [URL: TranscriptResult] = [:]
            let total = Double(max(streams.count, 1))
            for (i, stream) in streams.enumerated() {
                let bandStart = Double(i) / total
                let bandSize = 1.0 / total
                results[stream.audioURL] = try await transcribe(
                    audioURL: stream.audioURL,
                    options: stream.options,
                    progress: { f in
                        progress?(bandStart + max(0, min(1, f)) * bandSize)
                    }
                )
            }
            return results
        }
        return try await transcribeCombinedBatch(
            streams: streams,
            onProgress: progress,
            onStatus: status
        )
    }

    /// Pool every stream's chunks into one batch job. Uploads run with no
    /// concurrency cap (URLSession's HTTP/2 connection pool naturally
    /// throttles); JSONL keys are `s<streamIdx>-c<chunkIdx>` so we can
    /// reroute results back to the right stream after polling.
    private func transcribeCombinedBatch(
        streams: [TranscribeStream],
        onProgress: (@Sendable (Double) -> Void)?,
        onStatus: (@Sendable (TranscriptionSession.StageStatus) -> Void)?
    ) async throws -> [URL: TranscriptResult] {
        guard !apiKey.isEmpty else {
            throw TranscriptionError.modelLoadFailed(
                "Gemini API key not set. Open Settings → Transcription and paste your key."
            )
        }
        for stream in streams {
            guard FileManager.default.fileExists(atPath: stream.audioURL.path(percentEncoded: false)) else {
                throw TranscriptionError.audioMissing(stream.audioURL)
            }
        }

        // Progress bands (within transcribeBatch's 0...1):
        //   0 .. 0.04   chunk prep (parallel per stream — decode + AEC +
        //               chunking + WAV write; non-trivial on long meetings)
        //   0.04..0.10  chunk uploads (parallel, fast)
        //   0.10..0.12  JSONL upload + waitActive
        //   0.12..0.14  batch submit
        //   0.14..0.88  poll  (longest by far)
        //   0.88..0.92  responses download
        //   0.92..0.95  parse
        //   0.95..1.00  per-stream diarization (output stream only)
        let prepEnd = 0.04
        let uploadEnd = 0.10
        let jsonlUploadEnd = 0.12
        let submitEnd = 0.14
        let pollEnd = 0.88
        let downloadEnd = 0.92
        let parseEnd = 0.95

        onProgress?(0)

        // (1) Prepare chunks for every stream in parallel. Each stream's
        // prep is CPU+IO bound (decode → AEC → chunking → WAV write) and
        // pre-fa2cf57 the per-stream sync path overlapped this with
        // upload, so the batch path's serial prep felt like a regression
        // (bar pinned at 2% for 30-60 s on long meetings). Running the
        // streams concurrently halves wall time, and emitting a per-stream
        // fraction into a band-allocated aggregator keeps the bar moving
        // throughout instead of going dark until the first upload lands.
        let providerName = name
        let prepAggregator = ChunkProgressAggregator(count: streams.count) { fraction in
            onProgress?(fraction * prepEnd)
        }
        let perStreamChunks = try await withThrowingTaskGroup(
            of: (Int, [CloudAudioPrep.Chunk]).self
        ) { group in
            for (sIdx, stream) in streams.enumerated() {
                let streamIdx = sIdx
                let streamRef = stream
                group.addTask {
                    let chunks = try CloudAudioPrep.prepareChunks(
                        audioURL: streamRef.audioURL,
                        options: streamRef.options,
                        tempPrefix: "gemini-batch-s\(streamIdx)",
                        chunkDuration: 60,
                        providerName: providerName,
                        logTag: "Gemini",
                        onProgress: { f in
                            prepAggregator.update(index: streamIdx, fraction: f)
                        }
                    )
                    return (streamIdx, chunks)
                }
            }
            var collected: [Int: [CloudAudioPrep.Chunk]] = [:]
            while let (idx, chunks) = try await group.next() {
                collected[idx] = chunks
            }
            return collected
        }
        var allTempURLs: [URL] = []
        for chunks in perStreamChunks.values {
            for chunk in chunks where chunk.isTemp {
                allTempURLs.append(chunk.url)
            }
        }
        defer {
            for url in allTempURLs {
                try? FileManager.default.removeItem(at: url)
            }
        }
        onProgress?(prepEnd)

        // (2) Upload every chunk from every stream in parallel. No cap —
        // URLSession's per-host connection pool absorbs the burst, and
        // Files API uploads aren't subject to the per-minute generateContent
        // quota that drove the 8-cap on the sync path.
        let totalChunks = perStreamChunks.values.reduce(0) { $0 + $1.count }
        let aggregator = ChunkProgressAggregator(count: totalChunks) { fraction in
            onProgress?(prepEnd + fraction * (uploadEnd - prepEnd))
        }
        struct UploadedTagged: Sendable {
            let streamIndex: Int
            let chunkIndex: Int
            let offset: TimeInterval
            let uploaded: UploadedFile
        }
        let allUploaded = try await withThrowingTaskGroup(of: UploadedTagged.self) { group in
            var dispatched = 0
            for sIdx in perStreamChunks.keys.sorted() {
                let chunks = perStreamChunks[sIdx] ?? []
                for (cIdx, chunk) in chunks.enumerated() {
                    let progressIdx = dispatched
                    dispatched += 1
                    group.addTask { [self] in
                        let uploaded = try await uploadFile(at: chunk.url) { f in
                            aggregator.update(index: progressIdx, fraction: f * 0.5)
                        }
                        try await waitUntilActive(name: uploaded.name)
                        aggregator.update(index: progressIdx, fraction: 1.0)
                        return UploadedTagged(
                            streamIndex: sIdx,
                            chunkIndex: cIdx,
                            offset: chunk.offset,
                            uploaded: uploaded
                        )
                    }
                }
            }
            var collected: [UploadedTagged] = []
            collected.reserveCapacity(dispatched)
            while let item = try await group.next() {
                collected.append(item)
            }
            return collected
        }
        onProgress?(uploadEnd)

        // Best-effort cleanup of all chunk files when we're done.
        let chunkFileNames = allUploaded.map(\.uploaded.name)
        defer {
            Task { [weak self] in
                guard let self else { return }
                for n in chunkFileNames {
                    try? await self.deleteFile(name: n)
                }
            }
        }

        // (3) Build combined JSONL. Key includes both stream + chunk
        // indices so parseCombinedBatchResponses can route each line.
        let streamLanguages = Dictionary(
            uniqueKeysWithValues: streams.enumerated().map { ($0.offset, $0.element.options.language) }
        )
        let sortedUploaded = allUploaded
            .sorted { ($0.streamIndex, $0.chunkIndex) < ($1.streamIndex, $1.chunkIndex) }
            .map { (streamIndex: $0.streamIndex, chunkIndex: $0.chunkIndex, offset: $0.offset, uploaded: $0.uploaded) }
        let jsonlURL = try buildCombinedBatchJSONL(
            uploaded: sortedUploaded,
            languageByStream: streamLanguages
        )
        defer { try? FileManager.default.removeItem(at: jsonlURL) }

        let jsonlFile = try await uploadFile(at: jsonlURL, mimeOverride: "application/jsonl") { _ in }
        try await waitUntilActive(name: jsonlFile.name)
        onProgress?(jsonlUploadEnd)
        defer {
            Task { [weak self] in
                try? await self?.deleteFile(name: jsonlFile.name)
            }
        }

        // (4) Submit the batch.
        let batchName = try await submitBatch(inputFileName: jsonlFile.name)
        onProgress?(submitEnd)
        NSLog("[Meeting/Transcribe] Gemini combined batch submitted: %@ (chunks=%d, streams=%d)",
              batchName, totalChunks, streams.count)

        // (5) Poll until terminal.
        let responsesFileName = try await pollBatch(
            name: batchName,
            onProgress: { fraction in
                onProgress?(submitEnd + fraction * (pollEnd - submitEnd))
            },
            onStatus: onStatus
        )
        onProgress?(pollEnd)

        // (6) Download responses.
        let responsesData = try await downloadFile(name: responsesFileName)
        onProgress?(downloadEnd)
        Task { [weak self] in
            try? await self?.deleteFile(name: responsesFileName)
        }

        // (7) Parse + group by stream. Offsets are baked in by the
        // parser so timestamps are absolute within each stream.
        let segmentsByStream = try parseCombinedBatchResponses(
            jsonlData: responsesData,
            perStreamChunks: perStreamChunks
        )
        onProgress?(parseEnd)

        // (8) Per-stream finalization — diarize when needed, build the
        // TranscriptResult shape that callers expect.
        var results: [URL: TranscriptResult] = [:]
        // Only the streams that need diarization get a poll-able share of
        // the remaining 0.95...1.00 band; mic/known-speaker streams finish
        // instantly, so weighting by them would just stutter the bar.
        let diarStreams = streams.enumerated().filter { $0.element.options.withDiarization }
        let diarShare = diarStreams.isEmpty ? 0 : (1.0 - parseEnd) / Double(diarStreams.count)
        var diarBaseline = parseEnd
        for (sIdx, stream) in streams.enumerated() {
            let cloud = segmentsByStream[sIdx] ?? []
            if stream.options.withDiarization {
                let baseline = diarBaseline
                let span = diarShare
                let result = try await assembleResult(
                    cloudSegments: cloud,
                    audioURL: stream.audioURL,
                    options: stream.options,
                    diarizationProgress: { f in
                        onProgress?(baseline + f * span)
                    }
                )
                results[stream.audioURL] = result
                diarBaseline += span
            } else {
                results[stream.audioURL] = try await assembleResult(
                    cloudSegments: cloud,
                    audioURL: stream.audioURL,
                    options: stream.options,
                    diarizationProgress: nil
                )
            }
        }
        onProgress?(1.0)
        return results
    }

    /// Write a JSONL with one line per (stream, chunk) pair. Key carries
    /// both indices so `parseCombinedBatchResponses` can route each line
    /// back to the right stream's segment list.
    private nonisolated func buildCombinedBatchJSONL(
        uploaded: [(streamIndex: Int, chunkIndex: Int, offset: TimeInterval, uploaded: UploadedFile)],
        languageByStream: [Int: String?]
    ) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
        let fileURL = dir.appendingPathComponent("gemini-batch-combined-\(UUID().uuidString).jsonl")
        FileManager.default.createFile(atPath: fileURL.path(percentEncoded: false), contents: nil)
        guard let handle = try? FileHandle(forWritingTo: fileURL) else {
            throw TranscriptionError.providerFailed(name, underlying: GeminiError.batchFailed("could not open combined JSONL temp file for writing"))
        }
        defer { try? handle.close() }
        for entry in uploaded {
            let language = languageByStream[entry.streamIndex] ?? nil
            let request = makeGenerateRequestBody(
                fileURI: entry.uploaded.uri,
                mimeType: entry.uploaded.mimeType,
                language: language
            )
            let line: [String: Any] = [
                "key": "s\(entry.streamIndex)-c\(entry.chunkIndex)",
                "request": request,
            ]
            let data = try JSONSerialization.data(withJSONObject: line, options: [])
            handle.write(data)
            handle.write(Data([0x0A]))
        }
        return fileURL
    }

    /// Parse a combined batch's responses file, routing each line to its
    /// stream by the `s<i>-c<j>` key. Per-stream offsets are baked into
    /// segment timestamps; the caller gets back chronologically-ordered
    /// segments per stream ready for diarization / merging.
    private nonisolated func parseCombinedBatchResponses(
        jsonlData: Data,
        perStreamChunks: [Int: [CloudAudioPrep.Chunk]]
    ) throws -> [Int: [CloudSegment]] {
        guard let text = String(data: jsonlData, encoding: .utf8) else {
            throw TranscriptionError.providerFailed(name, underlying: GeminiError.batchFailed("responses file is not UTF-8"))
        }
        var byStreamAndChunk: [Int: [Int: [CloudSegment]]] = [:]
        var lineNumber = 0
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            lineNumber += 1
            let line = String(rawLine)
            guard let lineData = line.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any] else {
                NSLog("[Meeting/Transcribe] Gemini combined batch: line %d not JSON, skipping", lineNumber)
                continue
            }
            let key = (obj["key"] as? String)
                ?? ((obj["metadata"] as? [String: Any])?["key"] as? String)
            guard let key,
                  let parsed = parseCombinedKey(key),
                  let chunks = perStreamChunks[parsed.streamIndex],
                  parsed.chunkIndex >= 0,
                  parsed.chunkIndex < chunks.count else {
                NSLog("[Meeting/Transcribe] Gemini combined batch: line %d unparseable key, skipping", lineNumber)
                continue
            }
            if let err = obj["error"] as? [String: Any] {
                let msg = (err["message"] as? String) ?? "unknown"
                throw TranscriptionError.providerFailed(name, underlying: GeminiError.batchFailed(
                    "stream \(parsed.streamIndex) chunk \(parsed.chunkIndex) failed: \(msg)"
                ))
            }
            guard let response = obj["response"] else {
                NSLog("[Meeting/Transcribe] Gemini combined batch: line %d (s%d-c%d) has neither response nor error",
                      lineNumber, parsed.streamIndex, parsed.chunkIndex)
                continue
            }
            let envelopeData = try JSONSerialization.data(withJSONObject: response, options: [])
            let segs = try parseSegmentsFromEnvelope(envelopeData: envelopeData)
            let offset = chunks[parsed.chunkIndex].offset
            let absolute = segs.map {
                CloudSegment(start: $0.start + offset, end: $0.end + offset, text: $0.text, language: $0.language)
            }
            byStreamAndChunk[parsed.streamIndex, default: [:]][parsed.chunkIndex, default: []] += absolute
        }

        // Concatenate per-stream chunks in order. Empty chunks are valid
        // (silence). Total emptiness across the whole batch is an error.
        var ordered: [Int: [CloudSegment]] = [:]
        var totalSegmentCount = 0
        for (sIdx, chunks) in perStreamChunks {
            var streamSegs: [CloudSegment] = []
            for cIdx in 0..<chunks.count {
                streamSegs.append(contentsOf: byStreamAndChunk[sIdx]?[cIdx] ?? [])
            }
            ordered[sIdx] = streamSegs
            totalSegmentCount += streamSegs.count
        }
        if totalSegmentCount == 0 {
            throw TranscriptionError.providerFailed(name, underlying: GeminiError.batchFailed(
                "no usable segments in combined batch responses (\(lineNumber) lines parsed)"
            ))
        }
        return ordered
    }

    /// Parse `s<i>-c<j>` key into its components.
    private nonisolated func parseCombinedKey(_ key: String) -> (streamIndex: Int, chunkIndex: Int)? {
        guard key.hasPrefix("s") else { return nil }
        let rest = key.dropFirst()
        guard let dash = rest.firstIndex(of: "-") else { return nil }
        let streamPart = rest[rest.startIndex..<dash]
        let after = rest.index(after: dash)
        guard after < rest.endIndex else { return nil }
        let chunkPart = rest[after...]
        guard chunkPart.hasPrefix("c") else { return nil }
        let chunkNum = chunkPart.dropFirst()
        guard let s = Int(streamPart), let c = Int(chunkNum) else { return nil }
        return (s, c)
    }

    /// Shared finalization: cloud segments → TranscriptResult. For
    /// diarized streams we run SpeakerKit on the original audio file and
    /// merge with text segments; for known-speaker / mic streams we map
    /// directly with hallucination filtering.
    private func assembleResult(
        cloudSegments: [CloudSegment],
        audioURL: URL,
        options: TranscriptionOptions,
        diarizationProgress: (@Sendable (Double) -> Void)?
    ) async throws -> TranscriptResult {
        let totalDuration = cloudSegments.last.map { TimeInterval($0.end) } ?? 0
        let language = cloudSegments.first?.language ?? options.language
        if options.withDiarization {
            let timeline = try await runDiarization(
                audioURL: audioURL,
                expectedSpeakerCount: options.expectedSpeakerCount,
                onProgress: { f in diarizationProgress?(f) }
            )
            let merged = DiarizationMerger.merge(
                textSegments: cloudSegments.map {
                    DiarizationMerger.TextSegment(start: $0.start, end: $0.end, text: $0.text)
                },
                speakerTimeline: timeline,
                source: options.source
            )
            return TranscriptResult(
                provider: name,
                model: modelName,
                language: language,
                duration: totalDuration,
                segments: merged
            )
        }
        let speaker = options.knownSpeaker ?? SpeakerID.me
        let segments: [TranscriptSegment] = cloudSegments.compactMap { seg in
            let trimmed = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let dur = seg.end - seg.start
            if HallucinationFilter.isHallucination(text: trimmed, durationSeconds: dur) {
                return nil
            }
            return TranscriptSegment(
                start: seg.start,
                end: seg.end,
                speaker: speaker,
                text: trimmed,
                source: options.source
            )
        }
        return TranscriptResult(
            provider: name,
            model: modelName,
            language: language,
            duration: totalDuration,
            segments: segments
        )
    }

    // MARK: - Batch path
    //
    // Submits every chunk as one batch job via Gemini's Batch API instead
    // of fanning out individual `generateContent` calls. Google charges
    // 50% on batch tokens; in exchange the SLA is "up to 24 h" rather
    // than seconds. In practice batches usually finish in a few minutes,
    // so we poll inline and let the UI's progress bar reflect elapsed
    // time. See `geminiUseBatchAPI` in `AppPreferences` for the toggle.

    /// Run the batch flow end-to-end: upload chunk audio files, build the
    /// JSONL input, upload it, submit the batch, poll until done, download
    /// and parse the responses file. Reports 0...1 progress for the whole
    /// generate phase (the caller maps that into its own band).
    private func transcribeViaBatch(
        chunks: [CloudAudioPrep.Chunk],
        language: String?,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> [CloudSegment] {
        // Within-batch progress bands. Polling owns the bulk because we
        // genuinely don't know when Google will finish — assume ~10 min
        // and let the bar creep linearly with elapsed time, capped at the
        // band ceiling so it doesn't pin to 100% before the result lands.
        let uploadEnd = 0.10
        let jsonlUploadEnd = 0.13
        let submitEnd = 0.16
        let pollEnd = 0.94
        let downloadEnd = 0.98

        onProgress(0)

        // (1) Upload every chunk audio file in parallel. Reuse the existing
        // upload path; only the JSONL builder needs the resulting URIs.
        let uploadedChunks = try await uploadChunksParallel(chunks: chunks) { fraction in
            onProgress(fraction * uploadEnd)
        }
        onProgress(uploadEnd)

        // Best-effort cleanup for chunk files. Files API stores 48h, paid
        // quota is per-byte, so we want them gone when we're done.
        let chunkFileNames = uploadedChunks.map(\.uploaded.name)
        defer {
            Task { [weak self] in
                guard let self else { return }
                for name in chunkFileNames {
                    try? await self.deleteFile(name: name)
                }
            }
        }

        // (2) Build + upload JSONL input. One line per chunk; `key` is the
        // chunk index so we can reorder responses (batch output is not
        // guaranteed to preserve input order on disk).
        let jsonlURL = try buildBatchInputJSONL(uploaded: uploadedChunks, language: language)
        defer { try? FileManager.default.removeItem(at: jsonlURL) }

        let jsonlFile = try await uploadFile(at: jsonlURL, mimeOverride: "application/jsonl") { _ in }
        try await waitUntilActive(name: jsonlFile.name)
        onProgress(jsonlUploadEnd)
        defer {
            Task { [weak self] in
                try? await self?.deleteFile(name: jsonlFile.name)
            }
        }

        // (3) Submit the batch. We get back a batch resource name like
        // `batches/abc123` — the same name is used for both polling and
        // (eventually) the output-file lookup.
        let batchName = try await submitBatch(inputFileName: jsonlFile.name)
        onProgress(submitEnd)
        NSLog("[Meeting/Transcribe] Gemini batch submitted: %@", batchName)

        // (4) Poll until terminal state. Caller's band maps elapsed time
        // → 16...94% so the bar still moves while we wait. The
        // single-stream entry has no UI surface for status, so onStatus
        // is left nil — only the combined multi-stream path surfaces the
        // poll status to the queue.
        let responsesFileName = try await pollBatch(
            name: batchName,
            onProgress: { fraction in
                onProgress(submitEnd + fraction * (pollEnd - submitEnd))
            },
            onStatus: nil
        )
        onProgress(pollEnd)

        // (5) Download responses file. Best-effort delete after parsing —
        // we don't want it lingering against the user's quota.
        let responsesData = try await downloadFile(name: responsesFileName)
        onProgress(downloadEnd)
        Task { [weak self] in
            try? await self?.deleteFile(name: responsesFileName)
        }

        // (6) Parse JSONL → segments, with chunk offsets baked in.
        let segments = try parseBatchResponses(
            jsonlData: responsesData,
            chunks: chunks
        )
        onProgress(1.0)
        return segments
    }

    /// Holds an uploaded chunk + the chunk metadata needed to map results
    /// back into the source-audio timeline.
    private struct UploadedChunk: Sendable {
        let index: Int
        let offset: TimeInterval
        let uploaded: UploadedFile
    }

    /// Upload all chunks in parallel and wait for each to reach ACTIVE.
    /// Capped at `maxConcurrent` to match the sync path's burst budget.
    private func uploadChunksParallel(
        chunks: [CloudAudioPrep.Chunk],
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> [UploadedChunk] {
        let maxConcurrent = 8
        let aggregator = ChunkProgressAggregator(count: chunks.count) { fraction in
            onProgress(fraction)
        }
        let collected = try await withThrowingTaskGroup(of: UploadedChunk.self) { group in
            var dispatched = 0
            while dispatched < min(maxConcurrent, chunks.count) {
                let idx = dispatched
                let chunk = chunks[idx]
                group.addTask { [self] in
                    let uploaded = try await uploadFile(at: chunk.url) { f in
                        aggregator.update(index: idx, fraction: f * 0.5)
                    }
                    try await waitUntilActive(name: uploaded.name)
                    aggregator.update(index: idx, fraction: 1.0)
                    return UploadedChunk(index: idx, offset: chunk.offset, uploaded: uploaded)
                }
                dispatched += 1
            }
            var results: [UploadedChunk] = []
            results.reserveCapacity(chunks.count)
            while let result = try await group.next() {
                results.append(result)
                if dispatched < chunks.count {
                    let idx = dispatched
                    let chunk = chunks[idx]
                    group.addTask { [self] in
                        let uploaded = try await uploadFile(at: chunk.url) { f in
                            aggregator.update(index: idx, fraction: f * 0.5)
                        }
                        try await waitUntilActive(name: uploaded.name)
                        aggregator.update(index: idx, fraction: 1.0)
                        return UploadedChunk(index: idx, offset: chunk.offset, uploaded: uploaded)
                    }
                    dispatched += 1
                }
            }
            return results
        }
        return collected.sorted { $0.index < $1.index }
    }

    /// Write a JSONL file: one line per chunk, each carrying a `key`
    /// (chunk index as string) and the same per-chunk `request` shape
    /// used by the sync path. The Batch API ingests this file via the
    /// Files API and routes one row per worker.
    private nonisolated func buildBatchInputJSONL(
        uploaded: [UploadedChunk],
        language: String?
    ) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
        let fileURL = dir.appendingPathComponent("gemini-batch-\(UUID().uuidString).jsonl")
        FileManager.default.createFile(atPath: fileURL.path(percentEncoded: false), contents: nil)
        guard let handle = try? FileHandle(forWritingTo: fileURL) else {
            throw TranscriptionError.providerFailed(name, underlying: GeminiError.batchFailed("could not open JSONL temp file for writing"))
        }
        defer { try? handle.close() }
        for chunk in uploaded {
            let request = makeGenerateRequestBody(
                fileURI: chunk.uploaded.uri,
                mimeType: chunk.uploaded.mimeType,
                language: language
            )
            let line: [String: Any] = [
                "key": "chunk-\(chunk.index)",
                "request": request,
            ]
            let data = try JSONSerialization.data(withJSONObject: line, options: [])
            handle.write(data)
            handle.write(Data([0x0A]))  // newline
        }
        return fileURL
    }

    /// POST the batch request and return the new batch's resource name
    /// (`batches/...`). The endpoint returns either an Operation envelope
    /// (with `name` of the operation) or — historically — the BatchJob
    /// resource directly. We pull `name` from whichever one came back.
    private nonisolated func submitBatch(inputFileName: String) async throws -> String {
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(modelName):batchGenerateContent")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "batch": [
                "display_name": "meeting-\(UUID().uuidString.prefix(8))",
                "input_config": [
                    "file_name": inputFileName,
                ],
            ],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let (data, response) = try await sendWithRetry(label: "batch-submit") {
            try await urlSession.data(for: req)
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let summary = Self.explainGeminiError(status: status, body: data)
            throw TranscriptionError.providerFailed(name, underlying: GeminiError.batchFailed("submit — \(summary)"))
        }
        // Response shape (Operation envelope): `{ name: "batches/abc...", metadata: {...}, done: false }`
        // For the file-input flow `name` is the batch resource directly.
        struct Wire: Decodable { let name: String? }
        let parsed = (try? JSONDecoder().decode(Wire.self, from: data)) ?? Wire(name: nil)
        guard let name = parsed.name, !name.isEmpty else {
            let raw = String(data: data, encoding: .utf8) ?? ""
            throw TranscriptionError.providerFailed(self.name, underlying: GeminiError.batchFailed("submit response missing `name`: \(raw.prefix(500))"))
        }
        return name
    }

    /// Long-poll the batch until it reaches a terminal state. Returns the
    /// `responsesFile` name (`files/...`) on success. Polls every 5 s for
    /// the first minute, then 15 s — Google's published p50 for small
    /// batches is "a few minutes" so frequent early polling catches the
    /// fast finishes without spamming a slow run.
    private nonisolated func pollBatch(
        name: String,
        onProgress: @escaping @Sendable (Double) -> Void,
        onStatus: (@Sendable (TranscriptionSession.StageStatus) -> Void)?
    ) async throws -> String {
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/\(name)")!
        // Expected total wait used purely to drive the progress bar; the
        // actual deadline is `maxWait` below. 10 min ≈ p50 from Google's
        // docs for small audio batches.
        let expectedSeconds: TimeInterval = 600
        let maxWait: TimeInterval = 24 * 60 * 60  // batch SLA
        let started = Date()
        var pollCount = 0

        while Date().timeIntervalSince(started) < maxWait {
            try Task.checkCancellation()

            var req = URLRequest(url: url)
            req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
            let (data, response) = try await urlSession.data(for: req)
            pollCount += 1
            let now = Date()
            let elapsed = now.timeIntervalSince(started)

            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                let snapshot = parseBatchSnapshot(data: data)
                if let state = snapshot.state {
                    if state.hasSuffix("SUCCEEDED") {
                        if let file = snapshot.responsesFile {
                            onProgress(1.0)
                            onStatus?(TranscriptionSession.StageStatus(
                                updatedAt: now,
                                summary: "Gemini batch SUCCEEDED — fetching results"
                            ))
                            return file
                        }
                        throw TranscriptionError.providerFailed(self.name, underlying: GeminiError.batchFailed(
                            "batch SUCCEEDED but no responsesFile in payload"
                        ))
                    }
                    if state.hasSuffix("FAILED") || state.hasSuffix("CANCELLED") || state.hasSuffix("EXPIRED") {
                        let detail = snapshot.errorMessage ?? state
                        throw TranscriptionError.providerFailed(self.name, underlying: GeminiError.batchFailed(
                            "batch terminal state \(state): \(detail)"
                        ))
                    }
                    onStatus?(TranscriptionSession.StageStatus(
                        updatedAt: now,
                        summary: "Gemini batch \(humanizeBatchState(state)) · checked \(pollCount)× over \(formatElapsed(elapsed))"
                    ))
                } else {
                    onStatus?(TranscriptionSession.StageStatus(
                        updatedAt: now,
                        summary: "Gemini batch — no state yet · checked \(pollCount)× over \(formatElapsed(elapsed))"
                    ))
                }
            } else if let http = response as? HTTPURLResponse {
                onStatus?(TranscriptionSession.StageStatus(
                    updatedAt: now,
                    summary: "Gemini batch poll got HTTP \(http.statusCode) · checked \(pollCount)× over \(formatElapsed(elapsed))"
                ))
            }

            // Linear creep: 0...1 over `expectedSeconds`, capped at 0.98 so
            // the bar isn't pinned at 100% if the run takes longer.
            onProgress(min(0.98, elapsed / expectedSeconds))

            // Tight cadence early (catch fast finishes), slower cadence
            // later (don't burn quota on long tails).
            let interval: TimeInterval = elapsed < 60 ? 5 : 15
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
        throw TranscriptionError.providerFailed(self.name, underlying: GeminiError.batchFailed(
            "batch did not finish within 24h SLA"
        ))
    }

    /// Trim Google's `BATCH_STATE_RUNNING` / `BATCH_STATE_PENDING` etc.
    /// down to the readable suffix for status messages.
    private nonisolated func humanizeBatchState(_ state: String) -> String {
        if let suffix = state.split(separator: "_").last {
            return String(suffix)
        }
        return state
    }

    /// Compact "1h 6m" / "8m 32s" / "42s" style for status messages —
    /// matches the duration phrasing in the rest of the app.
    private nonisolated func formatElapsed(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total / 60) % 60
        let s = total % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }

    private struct BatchSnapshot {
        let state: String?
        let responsesFile: String?
        let errorMessage: String?
    }

    /// Pull the fields we care about out of a batch GET response.
    /// Defensive against shape drift: state can live at top-level, in
    /// `metadata`, or in `response`; responses-file likewise lives under
    /// either `response.output.responsesFile` or `metadata.output.responsesFile`.
    private nonisolated func parseBatchSnapshot(data: Data) -> BatchSnapshot {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return BatchSnapshot(state: nil, responsesFile: nil, errorMessage: nil)
        }
        // Walk likely homes for the BatchJob resource: top-level, then
        // metadata, then response.
        let candidates: [[String: Any]] = [
            root,
            (root["metadata"] as? [String: Any]) ?? [:],
            (root["response"] as? [String: Any]) ?? [:],
        ]

        var state: String?
        var responsesFile: String?
        for c in candidates {
            if state == nil, let s = c["state"] as? String { state = s }
            if responsesFile == nil,
               let output = c["output"] as? [String: Any] {
                if let f = output["responsesFile"] as? String { responsesFile = f }
                else if let f = output["responses_file"] as? String { responsesFile = f }
            }
        }

        var errorMessage: String?
        if let err = root["error"] as? [String: Any] {
            errorMessage = err["message"] as? String
        }

        return BatchSnapshot(state: state, responsesFile: responsesFile, errorMessage: errorMessage)
    }

    /// Download a Files API resource by name (`files/abc...`).
    ///
    /// Batch-output files don't support the standard
    /// `/download/v1beta/{name}?alt=media` endpoint (Google returns
    /// `INVALID_ARGUMENT — File download is not supported`). The Files
    /// API exposes a `downloadUri` field in the file metadata for these;
    /// fetch the metadata first, then GET that URI.
    ///
    /// We try `downloadUri` first and fall back to `?alt=media` for any
    /// file that doesn't expose it — keeps this helper usable for normal
    /// uploads in case the API surface evolves.
    private nonisolated func downloadFile(name: String) async throws -> Data {
        // (1) Fetch metadata. Includes the per-file `downloadUri`.
        let metaURL = URL(string: "https://generativelanguage.googleapis.com/v1beta/\(name)")!
        var metaReq = URLRequest(url: metaURL)
        metaReq.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        let (metaData, metaResponse) = try await sendWithRetry(label: "batch-download-meta") {
            try await urlSession.data(for: metaReq)
        }
        guard let metaHTTP = metaResponse as? HTTPURLResponse, metaHTTP.statusCode == 200 else {
            let status = (metaResponse as? HTTPURLResponse)?.statusCode ?? -1
            let summary = Self.explainGeminiError(status: status, body: metaData)
            throw TranscriptionError.providerFailed(self.name, underlying: GeminiError.batchFailed("download metadata — \(summary)"))
        }

        struct FileMeta: Decodable {
            let downloadUri: String?
        }
        let meta = (try? JSONDecoder().decode(FileMeta.self, from: metaData)) ?? FileMeta(downloadUri: nil)

        // (2) Pick a download URL. Batch outputs ship `downloadUri`; user-
        // uploaded inputs typically don't, so fall through to the legacy
        // media endpoint when missing.
        let downloadURL: URL = {
            if let uri = meta.downloadUri, let parsed = URL(string: uri) {
                return parsed
            }
            return URL(string: "https://generativelanguage.googleapis.com/download/v1beta/\(name)?alt=media")!
        }()

        var req = URLRequest(url: downloadURL)
        req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        let (data, response) = try await sendWithRetry(label: "batch-download") {
            try await urlSession.data(for: req)
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let summary = Self.explainGeminiError(status: status, body: data)
            throw TranscriptionError.providerFailed(self.name, underlying: GeminiError.batchFailed("download — \(summary)"))
        }
        return data
    }

    /// Parse the responses JSONL: one line per request, each carrying
    /// either a `response` envelope or an `error`. Map each line back to
    /// its chunk by `key` (we set `chunk-N` on the input side), apply the
    /// chunk's offset, and concatenate in source-audio order.
    private nonisolated func parseBatchResponses(
        jsonlData: Data,
        chunks: [CloudAudioPrep.Chunk]
    ) throws -> [CloudSegment] {
        guard let text = String(data: jsonlData, encoding: .utf8) else {
            throw TranscriptionError.providerFailed(name, underlying: GeminiError.batchFailed("responses file is not UTF-8"))
        }

        // Group responses by chunk index. Tolerate missing/duplicate keys —
        // we'll fail loudly at the end if a chunk has no segments at all.
        var byIndex: [Int: [CloudSegment]] = [:]
        var lineNumber = 0
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            lineNumber += 1
            let line = String(rawLine)
            guard let lineData = line.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any] else {
                NSLog("[Meeting/Transcribe] Gemini batch: line %d not JSON, skipping", lineNumber)
                continue
            }
            // `key` lives at top level when input was JSONL; some shapes
            // nest it under `metadata.key`. Try both.
            let key = (obj["key"] as? String)
                ?? ((obj["metadata"] as? [String: Any])?["key"] as? String)
            guard let key, key.hasPrefix("chunk-"),
                  let idx = Int(key.dropFirst("chunk-".count)),
                  idx >= 0, idx < chunks.count else {
                NSLog("[Meeting/Transcribe] Gemini batch: line %d has no parseable key, skipping", lineNumber)
                continue
            }
            // Per-line error → fail the whole batch. We can't ship a
            // partial transcript with gaps without misleading the user.
            if let err = obj["error"] as? [String: Any] {
                let msg = (err["message"] as? String) ?? "unknown"
                throw TranscriptionError.providerFailed(name, underlying: GeminiError.batchFailed(
                    "chunk \(idx) failed: \(msg)"
                ))
            }
            // Re-encode the `response` field as Data and reuse the same
            // envelope parser the sync path uses. Keeps the candidate /
            // finishReason / inner-JSON handling identical.
            guard let response = obj["response"] else {
                NSLog("[Meeting/Transcribe] Gemini batch: line %d (chunk %d) has neither response nor error, skipping", lineNumber, idx)
                continue
            }
            let envelopeData = try JSONSerialization.data(withJSONObject: response, options: [])
            let segs = try parseSegmentsFromEnvelope(envelopeData: envelopeData)
            // Apply chunk offset so segments line up with the original audio.
            let offset = chunks[idx].offset
            byIndex[idx, default: []] += segs.map {
                CloudSegment(start: $0.start + offset, end: $0.end + offset, text: $0.text, language: $0.language)
            }
        }

        // Concatenate in chunk order. Empty chunks are valid (silence) so
        // we don't error on them — only on a totally-empty batch.
        var ordered: [CloudSegment] = []
        for i in 0..<chunks.count {
            ordered.append(contentsOf: byIndex[i] ?? [])
        }
        if ordered.isEmpty {
            throw TranscriptionError.providerFailed(name, underlying: GeminiError.batchFailed(
                "no usable segments in batch responses (\(lineNumber) lines parsed)"
            ))
        }
        return ordered
    }

    // MARK: - Local SpeakerKit diarization

    private struct DiarizerBox: @unchecked Sendable { let kit: SpeakerKit }

    private func runDiarization(
        audioURL: URL,
        expectedSpeakerCount: Int?,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> [SpeakerSegment] {
        let dia = try await loadDiarizer()
        let path = audioURL.path(percentEncoded: false)
        return try await Self.diarize(
            box: dia,
            audioPath: path,
            expectedSpeakerCount: expectedSpeakerCount,
            providerName: name,
            onProgress: onProgress
        )
    }

    private func loadDiarizer() async throws -> DiarizerBox {
        if let box = diarizerBox { return box }
        if let existing = diarizerLoadTask { return try await existing.value }

        let downloadBase = ModelStorage.downloadBase().path(percentEncoded: false)
        let task = Task<DiarizerBox, Error> {
            let config = PyannoteConfig()
            config.verbose = false
            config.modelDownloadConfig = ModelDownloadConfig(
                downloadBase: downloadBase,
                modelRepo: "argmaxinc/speakerkit-coreml"
            )
            do {
                let kit = try await SpeakerKit(config)
                return DiarizerBox(kit: kit)
            } catch {
                throw TranscriptionError.modelLoadFailed(
                    "SpeakerKit pyannote: \(error.localizedDescription)"
                )
            }
        }
        diarizerLoadTask = task
        defer { diarizerLoadTask = nil }

        let box = try await task.value
        diarizerBox = box
        return box
    }

    private static func diarize(
        box: DiarizerBox,
        audioPath: String,
        expectedSpeakerCount: Int?,
        providerName: String,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> [SpeakerSegment] {
        do {
            let audio = try AudioProcessor.loadAudioAsFloatArray(
                fromPath: audioPath,
                channelMode: .sumChannels(nil)
            )
            let options = PyannoteDiarizationOptions(
                numberOfSpeakers: expectedSpeakerCount,
                clusterDistanceThreshold: 0.7
            )
            let progressCallback: (@Sendable (Progress) -> Void) = { p in
                onProgress(p.fractionCompleted)
            }
            let result = try await box.kit.diarize(
                audioArray: audio,
                options: options,
                progressCallback: progressCallback
            )
            return result.segments
        } catch let e as TranscriptionError {
            throw e
        } catch {
            throw TranscriptionError.providerFailed(providerName, underlying: error)
        }
    }

    // MARK: - Misc

    private nonisolated func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "m4a", "mp4": return "audio/mp4"
        case "wav":        return "audio/wav"
        case "mp3":        return "audio/mpeg"
        case "flac":       return "audio/flac"
        case "ogg":        return "audio/ogg"
        default:           return "application/octet-stream"
        }
    }
}

// MARK: - Errors

private enum GeminiError: LocalizedError {
    case uploadFailed(String)
    case fileProcessingFailed
    case fileProcessingTimeout
    case generateFailed(String)
    case batchFailed(String)

    var errorDescription: String? {
        switch self {
        case .uploadFailed(let msg): "Gemini upload failed: \(msg)"
        case .fileProcessingFailed: "Gemini reported the uploaded file as FAILED."
        case .fileProcessingTimeout: "Gemini did not finish processing the file within the timeout."
        case .generateFailed(let msg): "Gemini generateContent failed: \(msg)"
        case .batchFailed(let msg): "Gemini batch failed: \(msg)"
        }
    }
}
