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
    /// True when the model returns speaker-labeled segments natively
    /// (currently only `gpt-4o-transcribe-diarize`). When set, we skip
    /// the local SpeakerKit pass + IoU merger and consume the speaker
    /// field on each `diarized_json` segment directly.
    private let supportsNativeDiarization: Bool

    private let urlSession: URLSession

    private var diarizerBox: DiarizerBox?
    private var diarizerLoadTask: Task<DiarizerBox, Error>?

    init(
        apiKey: String,
        glossary: String,
        modelName: String = "gpt-4o-transcribe",
        responseFormat: String = "json",
        chunkDuration: TimeInterval = 60,
        supportsNativeDiarization: Bool = false
    ) {
        self.apiKey = apiKey
        self.glossary = glossary
        self.modelName = modelName
        self.responseFormat = responseFormat
        self.chunkDuration = chunkDuration
        self.supportsNativeDiarization = supportsNativeDiarization
        self.name = supportsNativeDiarization
            ? "OpenAI (\(modelName))"
            : "OpenAI (\(modelName)) + SpeakerKit"

        let config = URLSessionConfiguration.default
        // /v1/audio/transcriptions can take a few seconds per 60 s chunk
        // on healthy days, longer when the model is overloaded. 600 s per
        // request leaves comfortable retry headroom even when something
        // upstream stalls.
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

        // Chunk via shared helper. Voiced-aware on the mic stream; fixed
        // 60s chunks elsewhere. /v1/audio/transcriptions caps single
        // requests at 25 MB, which 60 s of 16k mono PCM stays well under.
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

        // Process chunks in parallel — each chunk = 1 multipart POST and
        // the URLSession is built for concurrent requests. 4 in flight
        // matches Gemini's setup and stays well under OpenAI's per-key
        // RPM limits on paid tiers.
        let maxConcurrent = 4
        let aggregator = ChunkProgressAggregator(count: chunks.count) { fraction in
            progress?(fraction * generateEnd)
        }
        let collected = try await withThrowingTaskGroup(of: (Int, [CloudSegment]).self) { group in
            var dispatched = 0
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
        let allCloudSegments = collected
            .sorted { $0.0 < $1.0 }
            .flatMap { $0.1 }
        progress?(generateEnd)

        let totalDuration = allCloudSegments.last.map { TimeInterval($0.end) } ?? 0
        let language = allCloudSegments.first?.language ?? options.language

        if options.withDiarization {
            // Native-diarization path: response already carries speaker
            // labels per segment, so skip SpeakerKit + IoU merging
            // entirely. Map "A"/"B"/… to a stable speaker_N index in
            // first-seen order — within a single API call the labels
            // are consistent, which is the typical case (a 12-min
            // meeting fits in one 1200 s chunk). Cross-chunk identity
            // continuity is a Phase-2 feature using known_speaker_refs.
            if supportsNativeDiarization {
                let segments = mapNativelyDiarizedSegments(
                    allCloudSegments,
                    source: options.source
                )
                progress?(1.0)
                return TranscriptResult(
                    provider: name,
                    model: modelName,
                    language: language,
                    duration: totalDuration,
                    segments: segments
                )
            }
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
        /// Set only when the response was `diarized_json` — carries the
        /// model's "A"/"B"/… speaker tag so the native-diarization path
        /// can map straight to `SpeakerID.diarized(N)` without a local
        /// SpeakerKit run.
        let speakerLabel: String?
    }

    /// Build TranscriptSegments from the diarize-model's already-labeled
    /// segments. Maps the model's letter labels (A, B, C…) to
    /// `speaker_0`, `speaker_1`, … in first-seen order so the rest of
    /// the app — which keys speaker rename / library overrides off the
    /// diarized index — sees the same shape it does from SpeakerKit.
    private func mapNativelyDiarizedSegments(
        _ segments: [CloudSegment],
        source: AudioSource
    ) -> [TranscriptSegment] {
        var labelIndex: [String: Int] = [:]
        var out: [TranscriptSegment] = []
        out.reserveCapacity(segments.count)
        for seg in segments {
            let trimmed = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let dur = seg.end - seg.start
            if HallucinationFilter.isHallucination(text: trimmed, durationSeconds: dur) {
                continue
            }
            let speaker: SpeakerID = {
                guard let raw = seg.speakerLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !raw.isEmpty else {
                    return SpeakerID(rawValue: "unknown")
                }
                if let idx = labelIndex[raw] {
                    return SpeakerID.diarized(idx)
                }
                let idx = labelIndex.count
                labelIndex[raw] = idx
                return SpeakerID.diarized(idx)
            }()
            out.append(TranscriptSegment(
                start: seg.start,
                end: seg.end,
                speaker: speaker,
                text: trimmed,
                source: source
            ))
        }
        out.sort { $0.start < $1.start }
        return out
    }

    private nonisolated func transcribeOneChunk(
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
                language: seg.language,
                speakerLabel: seg.speakerLabel
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
    private nonisolated func formatPrompt() -> String {
        guard !glossary.isEmpty else { return "" }
        if modelName.hasPrefix("gpt-4o") {
            return "This is an iOS/Android mobile development meeting at Finnomena recorded in Thai with frequent English technical terms. Topics may include: \(glossary)."
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

    private nonisolated func postTranscription(
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

        if responseFormat == "diarized_json" {
            // gpt-4o-transcribe-diarize is finicky about extra fields:
            // sending `language`, `temperature`, or `prompt` reliably
            // returns HTTP 500 with a generic "server_error" instead of
            // a structured 4xx (poor input validation on their side).
            // The minimal-fields shape — model + file + response_format
            // + chunking_strategy — matches the Python SDK example and
            // is the only combination community reports confirm working.
            addField("chunking_strategy", "auto")
        } else {
            addField("temperature", "0")
            if let language { addField("language", language) }
            let promptText = formatPrompt()
            if !promptText.isEmpty { addField("prompt", promptText) }
        }

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
            // Dump the full body to Console — `summary` is truncated for
            // the user-facing error and the structured envelope skips
            // fields like `param`/`code` that are often the only clue
            // for diarize-model 500s.
            NSLog("[Meeting/Transcribe] OpenAI %d full body:\n%@",
                  http.statusCode,
                  String(data: data, encoding: .utf8) ?? "<non-utf8>")
            throw TranscriptionError.providerFailed(name, underlying: OpenAIError.requestFailed(summary))
        }

        // Two response shapes share the same envelope at this layer:
        //   - whisper-1 (verbose_json): {language, segments[{start,end,text}], text}
        //   - gpt-4o-* (json):          {text}
        //   - gpt-4o-transcribe-diarize (diarized_json):
        //         {language, full_text, segments[{start,end,text,speaker, ...}]}
        // One decoder with optional fields covers all three.
        struct Wire: Decodable {
            struct Seg: Decodable {
                let start: Double
                let end: Double
                let text: String
                let speaker: String?
            }
            let language: String?
            let segments: [Seg]?
            let text: String?
            let full_text: String?
        }
        let parsed: Wire
        do {
            parsed = try JSONDecoder().decode(Wire.self, from: data)
        } catch {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw TranscriptionError.providerFailed(name, underlying: OpenAIError.requestFailed(
                "decode response: \(error.localizedDescription) — \(body.prefix(500))"
            ))
        }

        if let segments = parsed.segments, !segments.isEmpty {
            return segments.map {
                CloudSegment(
                    start: $0.start,
                    end: $0.end,
                    text: $0.text,
                    language: parsed.language,
                    speakerLabel: $0.speaker
                )
            }
        }

        // Plain-text fallback. The model returned just `text` (likely
        // gpt-4o-transcribe ignoring verbose_json). Wrap as a single
        // chunk-bound segment so the rest of the pipeline gets the text;
        // diarization will only be able to assign a single speaker per
        // chunk, but that's better than dropping the audio.
        let fallbackText = parsed.text ?? parsed.full_text ?? ""
        guard !fallbackText.isEmpty else {
            throw TranscriptionError.providerFailed(name, underlying: OpenAIError.requestFailed(
                "Empty response (no segments, no text)"
            ))
        }
        NSLog("[Meeting/Transcribe] OpenAI %@ returned plain text (no segments) — falling back to chunk-bound segment",
              modelName)
        return [CloudSegment(
            start: 0,
            end: chunkDuration,
            text: fallbackText,
            language: parsed.language,
            speakerLabel: nil
        )]
    }

    // MARK: - Retry + error parsing

    private nonisolated func sendWithRetry(
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

    private nonisolated func shouldRetryStatus(_ code: Int) -> Bool {
        // OpenAI 429 is usually RPM throttling, not daily quota — short
        // backoff often clears it. So unlike Gemini, we DO retry 429.
        code == 429 || (500...599).contains(code)
    }

    private nonisolated func retryDelay(attempt: Int) -> Double {
        // 3s, 9s, 27s. OpenAI throttle windows are usually <1 min.
        3.0 * pow(3.0, Double(attempt - 1))
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
