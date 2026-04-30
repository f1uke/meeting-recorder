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

    private let urlSession: URLSession

    private var diarizerBox: DiarizerBox?
    private var diarizerLoadTask: Task<DiarizerBox, Error>?

    init(
        apiKey: String,
        glossary: String,
        modelName: String = "gemini-2.5-flash"
    ) {
        self.apiKey = apiKey
        self.glossary = glossary
        self.modelName = modelName
        self.name = "Gemini (\(modelName)) + SpeakerKit"

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

        // Chunk the audio at 90 s boundaries before sending to Gemini.
        // Without chunking, LLM-based transcription drifts on long audio:
        // attention dilutes → timestamps wander, late content gets
        // summarized or hallucinated. Empirically 60 s was the safe
        // window for Flash; 2.5 Pro holds attention longer so 90 s
        // works without quality loss and shaves a third off the chunk
        // count for long meetings (2 hr → 80 instead of 120 chunks,
        // saving ~33% of the per-day RPD ceiling). Mic preprocessing
        // (AEC / normalize / mute gate) is folded into chunk preparation
        // since both need the float array.
        let chunks = try CloudAudioPrep.prepareChunks(
            audioURL: audioURL,
            options: options,
            tempPrefix: "gemini",
            chunkDuration: 90,
            providerName: name,
            logTag: "Gemini"
        )
        defer {
            for chunk in chunks where chunk.isTemp {
                try? FileManager.default.removeItem(at: chunk.url)
            }
        }

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
                let language = options.language
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
                    let language = options.language
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
        let allCloudSegments = collected
            .sorted { $0.0 < $1.0 }
            .flatMap { $0.1 }
        progress?(generateEnd)

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
    /// Reports 0...1 progress for the bytes phase.
    private nonisolated func uploadFile(
        at audioURL: URL,
        onProgress: @Sendable (Double) -> Void
    ) async throws -> UploadedFile {
        let fileSize = try (FileManager.default.attributesOfItem(atPath: audioURL.path(percentEncoded: false))[.size] as? Int) ?? 0
        let mimeType = mimeType(for: audioURL)

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

        let systemText = systemInstruction(language: language)
        let userText = "Transcribe the attached audio. Output JSON matching the schema. Each segment is one continuous utterance, typically 5-15 seconds. Timestamps are in seconds (decimal), measured from the start of the audio."

        // responseSchema (TYPE-CAPS form) is the most broadly-supported
        // structured-output shape on 2.5-flash. Number/string vocab matches
        // the OpenAPI subset Gemini accepts.
        let body: [String: Any] = [
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
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            let body = String(data: data, encoding: .utf8) ?? ""
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
        You transcribe meeting audio for a software development team.
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

    var errorDescription: String? {
        switch self {
        case .uploadFailed(let msg): "Gemini upload failed: \(msg)"
        case .fileProcessingFailed: "Gemini reported the uploaded file as FAILED."
        case .fileProcessingTimeout: "Gemini did not finish processing the file within the timeout."
        case .generateFailed(let msg): "Gemini generateContent failed: \(msg)"
        }
    }
}
