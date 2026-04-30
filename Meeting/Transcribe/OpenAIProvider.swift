import Foundation
import WhisperKit
import SpeakerKit

/// Cloud transcription via OpenAI's `/v1/audio/transcriptions` endpoint.
///
/// Flow per chunk:
/// 1. Multipart POST the audio + model + `verbose_json` response_format +
///    `prompt` (glossary) + `language`.
/// 2. Parse `segments[]` from `verbose_json` response. Models that don't
///    support `verbose_json` (e.g. `gpt-4o-transcribe` may only return
///    plain `json` with `text`) fall back to a single chunk-bound segment
///    so the pipeline still produces output, just at coarser timestamp
///    granularity.
/// 3. Offset segment timestamps by the chunk's start time.
///
/// Uses the shared `CloudAudioPrep` helper for decode + AEC + chunking
/// so mic preprocessing matches every other provider.
///
/// Diarization runs locally via SpeakerKit on the original audio (same
/// pattern as `GeminiProvider`). OpenAI does ship `gpt-4o-transcribe-
/// diarize` with built-in diarization but the response shape isn't
/// documented in the same place; punted to a follow-up.
actor OpenAIProvider: TranscriptionProvider {
    nonisolated let name: String

    private let apiKey: String
    private let glossary: String
    private let modelName: String
    private let responseFormat: String
    private let chunkDuration: TimeInterval

    private let urlSession: URLSession

    private var diarizerBox: DiarizerBox?
    private var diarizerLoadTask: Task<DiarizerBox, Error>?

    init(
        apiKey: String,
        glossary: String,
        modelName: String = "gpt-4o-transcribe",
        responseFormat: String = "json",
        chunkDuration: TimeInterval = 90
    ) {
        self.apiKey = apiKey
        self.glossary = glossary
        self.modelName = modelName
        self.responseFormat = responseFormat
        self.chunkDuration = chunkDuration
        self.name = "OpenAI (\(modelName)) + SpeakerKit"

        let config = URLSessionConfiguration.default
        // OpenAI's transcription endpoint can take 30-90s per 6-min chunk.
        // 600s per request gives plenty of headroom for slow models / small
        // files retrying.
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
                "OpenAI API key not set. Open Settings → Transcription and paste your key."
            )
        }
        guard FileManager.default.fileExists(atPath: audioURL.path(percentEncoded: false)) else {
            throw TranscriptionError.audioMissing(audioURL)
        }

        let generateEnd = options.withDiarization ? 0.70 : 1.0
        progress?(0)

        // Chunk via shared helper. Same 6-min strategy as Gemini, plus the
        // 25 MB request-size limit on /v1/audio/transcriptions makes
        // chunking mandatory anyway (1 hr m4a ≈ 28 MB).
        let chunks = try CloudAudioPrep.prepareChunks(
            audioURL: audioURL,
            options: options,
            tempPrefix: "openai",
            chunkDuration: chunkDuration,
            providerName: name,
            logTag: "OpenAI"
        )
        defer {
            for chunk in chunks where chunk.isTemp {
                try? FileManager.default.removeItem(at: chunk.url)
            }
        }

        var allCloudSegments: [CloudSegment] = []
        for (idx, chunk) in chunks.enumerated() {
            let chunkStart = generateEnd * Double(idx) / Double(chunks.count)
            let chunkBand = generateEnd / Double(chunks.count)
            let chunkProgress: @Sendable (Double) -> Void = { fraction in
                progress?(chunkStart + max(0, min(1, fraction)) * chunkBand)
            }
            let segs = try await transcribeOneChunk(
                audioURL: chunk.url,
                offset: chunk.offset,
                language: options.language,
                onProgress: chunkProgress
            )
            allCloudSegments.append(contentsOf: segs)
        }
        progress?(generateEnd)

        let totalDuration = allCloudSegments.last.map { TimeInterval($0.end) } ?? 0
        let language = allCloudSegments.first?.language ?? options.language

        if options.withDiarization {
            let timeline = try await runDiarization(
                audioURL: audioURL,
                expectedSpeakerCount: options.expectedSpeakerCount
            ) { fraction in
                progress?(generateEnd + fraction * (1.0 - generateEnd))
            }
            let merged = DiarizationMerger.merge(
                textSegments: allCloudSegments.map {
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

        let speaker = options.knownSpeaker ?? SpeakerID.me
        let segments: [TranscriptSegment] = allCloudSegments.compactMap { seg in
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

    private struct CloudSegment: Sendable {
        let start: TimeInterval
        let end: TimeInterval
        let text: String
        let language: String?
    }

    private func transcribeOneChunk(
        audioURL: URL,
        offset: TimeInterval,
        language: String?,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> [CloudSegment] {
        // OpenAI's transcription endpoint is single-shot — there's no
        // separate upload step like Gemini's Files API. We build the
        // multipart body, POST it, parse the result.
        let uploadEnd = 0.50  // upload + inference is one round trip; pre/post split is arbitrary
        onProgress(0)

        let chunkDuration = chunkDurationSeconds(at: audioURL) ?? 0
        let segments = try await postTranscription(
            audioURL: audioURL,
            language: language,
            chunkDuration: chunkDuration,
            onUploadProgress: { fraction in
                onProgress(fraction * uploadEnd)
            }
        )
        onProgress(1.0)

        return segments.compactMap { seg in
            if isPromptRegurgitation(text: seg.text) {
                NSLog("[Meeting/Transcribe] OpenAI dropped echoed-glossary segment at %.1fs: %@",
                      seg.start + offset, String(seg.text.prefix(80)))
                return nil
            }
            return CloudSegment(
                start: seg.start + offset,
                end: seg.end + offset,
                text: seg.text,
                language: seg.language
            )
        }
    }

    /// Ask AVAudioFile for the chunk's wall-clock length so we can fall
    /// back to chunk-bound segments when the model returns plain text.
    /// Cheap header parse, no decode. Returns 0 if the file is unreadable
    /// — caller still gets a useful chunk-level segment, just with end=0.
    private nonisolated func chunkDurationSeconds(at url: URL) -> TimeInterval? {
        // We wrote the chunk as 16k mono 16-bit PCM WAV — header has
        // sample-rate and data length. Reading the file is overkill;
        // approximate from file size minus the 44-byte header.
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false)),
              let size = attrs[.size] as? Int else { return nil }
        let dataBytes = max(0, size - 44)
        let samples = dataBytes / 2  // 16-bit mono
        return Double(samples) / 16000
    }

    // MARK: - Prompt formatting + regurgitation guard

    /// Wrap the user's glossary into a per-model prompt shape.
    ///
    /// `whisper-1` expects a comma-separated keyword list — that's exactly
    /// what `glossary` already is. `gpt-4o-*` are LLMs and their prompt
    /// is "free text describing context"; if we hand them a bare keyword
    /// list, they regurgitate it verbatim on silent chunks (the model
    /// has nothing else to "transcribe", so it echoes the prompt). Wrap
    /// it in a sentence so an echo would at least look unnatural and the
    /// downstream filter can catch it.
    private func formatPrompt() -> String {
        guard !glossary.isEmpty else { return "" }
        if modelName.hasPrefix("gpt-4o") {
            return "This is a software development meeting recorded in Thai with frequent English technical terms. Topics may include: \(glossary)."
        }
        return glossary
    }

    /// Detect when the model echoed our prompt back as the transcription.
    /// Triggers when the returned text either contains a verbatim chunk
    /// of the glossary fingerprint, or when more than half of the
    /// glossary's terms appear in the text — both shapes only happen on
    /// genuine echo, not on real speech.
    private nonisolated func isPromptRegurgitation(text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !glossary.isEmpty else { return false }

        // Verbatim fingerprint check: take the first ~60 chars of the
        // glossary, see if it appears in the output.
        let fingerprint = String(glossary.prefix(60))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if fingerprint.count >= 30, trimmed.contains(fingerprint) {
            return true
        }

        // Term-density check: how many of the glossary's terms appear in
        // the text? Real speech might pick up 1-2 terms; only an echo
        // hits >50%.
        let terms = glossary
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard terms.count >= 5 else { return false }
        let found = terms.filter { trimmed.localizedCaseInsensitiveContains($0) }.count
        return Double(found) / Double(terms.count) > 0.5
    }

    // MARK: - Multipart upload + parse

    private func postTranscription(
        audioURL: URL,
        language: String?,
        chunkDuration: TimeInterval,
        onUploadProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> [CloudSegment] {
        let url = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
        let boundary = "Boundary-\(UUID().uuidString)"
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let fileData: Data
        do {
            fileData = try Data(contentsOf: audioURL)
        } catch {
            throw TranscriptionError.providerFailed(name, underlying: error)
        }

        // Build multipart body. 6-min WAV chunks are ~12 MB so loading
        // into memory is fine; if we ever raise the chunk cap we'd want
        // a streaming InputStream body instead.
        var body = Data()
        func addField(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }

        addField("model", modelName)
        addField("response_format", responseFormat)
        addField("temperature", "0")
        if let language { addField("language", language) }
        let promptText = formatPrompt()
        if !promptText.isEmpty { addField("prompt", promptText) }

        // File part — the chunk WAV from CloudAudioPrep.
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(audioURL.lastPathComponent)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n".data(using: .utf8)!)

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body
        req.setValue(String(body.count), forHTTPHeaderField: "Content-Length")

        onUploadProgress(0.0)
        let (data, response) = try await sendWithRetry(label: "transcriptions") {
            try await urlSession.data(for: req)
        }
        onUploadProgress(1.0)

        guard let http = response as? HTTPURLResponse else {
            throw TranscriptionError.providerFailed(name, underlying: OpenAIError.requestFailed("no HTTP response"))
        }
        guard http.statusCode == 200 else {
            let summary = Self.explainOpenAIError(status: http.statusCode, body: data)
            throw TranscriptionError.providerFailed(name, underlying: OpenAIError.requestFailed(summary))
        }

        // Try verbose_json first (whisper-1 supports it). Fall back to
        // plain-text {text:...} for models that ignored response_format.
        struct Verbose: Decodable {
            struct Seg: Decodable {
                let start: Double
                let end: Double
                let text: String
            }
            let language: String?
            let segments: [Seg]?
            let text: String?
        }
        let parsed: Verbose
        do {
            parsed = try JSONDecoder().decode(Verbose.self, from: data)
        } catch {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw TranscriptionError.providerFailed(name, underlying: OpenAIError.requestFailed(
                "decode response: \(error.localizedDescription) — \(body.prefix(500))"
            ))
        }

        if let segments = parsed.segments, !segments.isEmpty {
            return segments.map {
                CloudSegment(start: $0.start, end: $0.end, text: $0.text, language: parsed.language)
            }
        }

        // Plain-text fallback. The model returned just `text` (likely
        // gpt-4o-transcribe ignoring verbose_json). Wrap as a single
        // chunk-bound segment so the rest of the pipeline gets the text;
        // diarization will only be able to assign a single speaker per
        // chunk, but that's better than dropping the audio.
        guard let text = parsed.text, !text.isEmpty else {
            throw TranscriptionError.providerFailed(name, underlying: OpenAIError.requestFailed(
                "Empty response (no segments, no text)"
            ))
        }
        NSLog("[Meeting/Transcribe] OpenAI %@ returned plain text (no segments) — falling back to chunk-bound segment",
              modelName)
        return [CloudSegment(start: 0, end: chunkDuration, text: text, language: parsed.language)]
    }

    // MARK: - Retry + error parsing

    private func sendWithRetry(
        label: String,
        maxAttempts: Int = 3,
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
                    let summary = Self.explainOpenAIError(status: http.statusCode, body: data)
                    let delay = retryDelay(attempt: attempt)
                    NSLog("[Meeting/Transcribe] OpenAI %@: %@, retrying in %.1fs (attempt %d/%d)",
                          label, summary, delay, attempt, maxAttempts)
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }
                return (data, response)
            } catch {
                if attempt < maxAttempts, isRetryableNetworkError(error) {
                    let delay = retryDelay(attempt: attempt)
                    NSLog("[Meeting/Transcribe] OpenAI %@: network error, retrying in %.1fs (attempt %d/%d): %@",
                          label, delay, attempt, maxAttempts, error.localizedDescription)
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }
                throw error
            }
        }
    }

    private func shouldRetryStatus(_ code: Int) -> Bool {
        // OpenAI 429 is usually RPM throttling, not daily quota — short
        // backoff often clears it. So unlike Gemini, we DO retry 429.
        code == 429 || (500...599).contains(code)
    }

    private func retryDelay(attempt: Int) -> Double {
        // 3s, 9s, 27s. OpenAI throttle windows are usually <1 min.
        3.0 * pow(3.0, Double(attempt - 1))
    }

    private func isRetryableNetworkError(_ error: Error) -> Bool {
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

    private static func explainOpenAIError(status: Int, body: Data) -> String {
        struct Envelope: Decodable {
            struct ErrBody: Decodable {
                let message: String?
                let type: String?
                let code: String?
            }
            let error: ErrBody?
        }
        if let envelope = try? JSONDecoder().decode(Envelope.self, from: body),
           let err = envelope.error {
            let message = err.message ?? "no message"
            if let t = err.type, !t.isEmpty {
                return "\(t) (HTTP \(status)): \(message)"
            }
            return "HTTP \(status): \(message)"
        }
        let raw = String(data: body, encoding: .utf8) ?? ""
        return "HTTP \(status) — \(raw.prefix(300))"
    }

    // MARK: - Local SpeakerKit diarization (mirror of GeminiProvider's path)

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
}

// MARK: - Errors

private enum OpenAIError: LocalizedError {
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .requestFailed(let msg): "OpenAI transcription failed: \(msg)"
        }
    }
}
