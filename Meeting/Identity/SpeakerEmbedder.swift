import Foundation
import CoreML
import Accelerate

/// MLModel is non-final / non-Sendable, but Core ML internals are thread-safe
/// for prediction. Wrap in @unchecked Sendable so we can hand the model off to
/// nonisolated static helpers (matching `LocalProvider`'s KitBox pattern).
private struct ModelBox: @unchecked Sendable {
    let model: MLModel
}

/// Wraps the argmax pyannote-v3-w8a16 Core ML embedder.
///
/// The model is the same one SpeakerKit loads internally, but its public API
/// doesn't expose per-cluster centroids — so we load the `.mlmodelc` files
/// directly from the path SpeakerKit's first-time download has populated.
///
/// Pipeline ("isolate-then-embed"):
///   1. Caller pre-slices the meeting audio into per-speaker [Float] segments.
///   2. We concatenate, chunk to 30-second windows with 1s overlap.
///   3. Per chunk: preEmbedder (waveform → features), embedder (features +
///      ones-mask → 256-dim per slot), take slot 0, L2-normalize.
///   4. Average chunks → final L2-normalized 256-dim centroid.
///
/// Audio < `minDurationSeconds` (5s) returns nil so the caller can skip.
actor SpeakerEmbedder {
    static let modelTag = "pyannote-v3-w8a16"

    /// Pyannote v3 embedder expects exactly 30 seconds of 16 kHz mono per chunk.
    private static let chunkSamples = 480_000
    /// 1s overlap → hop 29s = 464_000 samples.
    private static let hopSamples = 464_000
    /// Minimum total per-speaker audio before we'll embed.
    private static let minDurationSeconds: Double = 5.0
    /// Output dim — verified by integration test, matches pyannote-v3-w8a16 metadata.
    static let outputDim = 256
    /// Frame count of the speaker_masks dim (also pre-set by the model).
    private static let maskFrames = 1767
    /// Max-speaker slot dim of speaker_masks — the model allocates up to 64
    /// concurrent speakers per window; we always use slot 0.
    private static let maskSpeakerSlots = 64

    private var preEmbedder: ModelBox?
    private var embedder: ModelBox?
    private var loadTask: Task<Void, Error>?

    static func modelsAvailable() -> Bool {
        guard let (a, b) = try? modelURLs() else { return false }
        return FileManager.default.fileExists(atPath: a.path(percentEncoded: false))
            && FileManager.default.fileExists(atPath: b.path(percentEncoded: false))
    }

    private static func modelURLs() throws -> (URL, URL) {
        let base = ModelStorage.downloadBase()
            .appendingPathComponent("models/argmaxinc/speakerkit-coreml/speaker_embedder/pyannote-v3/W8A16",
                                    isDirectory: true)
        return (
            base.appendingPathComponent("SpeakerEmbedderPreprocessor.mlmodelc"),
            base.appendingPathComponent("SpeakerEmbedder.mlmodelc")
        )
    }

    func loadModels() async throws {
        if preEmbedder != nil && embedder != nil { return }
        if let existing = loadTask { return try await existing.value }
        let task = Task<Void, Error> { [weak self] in
            let (preURL, embURL) = try Self.modelURLs()
            let cfg = MLModelConfiguration()
            cfg.computeUnits = .cpuAndNeuralEngine
            let p = ModelBox(model: try await MLModel.load(contentsOf: preURL, configuration: cfg))
            let e = ModelBox(model: try await MLModel.load(contentsOf: embURL, configuration: cfg))
            await self?.adopt(pre: p, emb: e)
        }
        loadTask = task
        defer { loadTask = nil }
        try await task.value
    }

    private func adopt(pre: ModelBox, emb: ModelBox) {
        self.preEmbedder = pre
        self.embedder = emb
    }

    func unloadModels() {
        preEmbedder = nil
        embedder = nil
    }

    /// Returns an L2-normalized 256-dim centroid, or nil if total audio < 5s.
    /// `audioSegments` must already be 16 kHz mono float arrays.
    func embed(audioSegments: [[Float]]) async throws -> [Float]? {
        let totalSamples = audioSegments.reduce(0) { $0 + $1.count }
        let totalSeconds = Double(totalSamples) / 16_000.0
        guard totalSeconds >= Self.minDurationSeconds else { return nil }

        try await loadModels()
        guard let pre = preEmbedder, let emb = embedder else {
            throw SpeakerEmbedderError.modelsNotLoaded
        }

        let concat = SpeakerEmbedderHelpers.concatenate(audioSegments)
        let chunks: [[Float]]
        if concat.count < Self.chunkSamples {
            // Pad short audio (5s–30s range) up to one 30s window.
            var padded = concat
            padded.append(contentsOf: [Float](repeating: 0, count: Self.chunkSamples - concat.count))
            chunks = [padded]
        } else {
            chunks = SpeakerEmbedderHelpers.chunk(
                concat,
                chunkSamples: Self.chunkSamples,
                hopSamples: Self.hopSamples
            )
        }
        guard !chunks.isEmpty else { return nil }

        var accum = [Float](repeating: 0, count: Self.outputDim)
        for chunk in chunks {
            let vec = try await Self.embedChunk(chunk, preEmbedder: pre, embedder: emb)
            for i in 0..<Self.outputDim { accum[i] += vec[i] }
        }
        return SpeakerEmbedderHelpers.l2Normalize(accum)
    }

    /// Run one 30s chunk through preprocessor + embedder. Returns the 256-dim
    /// L2-normalized speaker embedding from slot 0 of the model output.
    private static func embedChunk(
        _ chunk: [Float],
        preEmbedder pre: ModelBox,
        embedder emb: ModelBox
    ) async throws -> [Float] {
        precondition(chunk.count == chunkSamples, "embedChunk requires exactly \(chunkSamples) samples")

        // Step 1 — preprocessor: waveforms [1, 480000] → preprocessor_output_1 [1, 2998, 80]
        let waveform = try MLMultiArray(shape: [1, NSNumber(value: chunkSamples)], dataType: .float32)
        let wfPtr = waveform.dataPointer.bindMemory(to: Float32.self, capacity: chunk.count)
        chunk.withUnsafeBufferPointer { buf in
            wfPtr.update(from: buf.baseAddress!, count: chunk.count)
        }
        let preInput = try MLDictionaryFeatureProvider(dictionary: ["waveforms": waveform])
        let preOut = try await pre.model.prediction(from: preInput)
        guard let features = preOut.featureValue(for: "preprocessor_output_1")?.multiArrayValue else {
            throw SpeakerEmbedderError.invalidModelOutput("preprocessor_output_1 missing")
        }

        // Step 2 — embedder: features + speaker_masks [1, 64, 1767] → speaker_embeddings [1, 64, 256]
        let masks = try MLMultiArray(shape: [1,
                                             NSNumber(value: maskSpeakerSlots),
                                             NSNumber(value: maskFrames)],
                                     dataType: .float32)
        let maskPtr = masks.dataPointer.bindMemory(to: Float32.self, capacity: masks.count)
        memset(maskPtr, 0, masks.count * MemoryLayout<Float32>.size)
        // Slot 0 = first maskFrames elements in row-major [batch, slot, frame] layout
        for f in 0..<maskFrames {
            maskPtr[f] = 1.0
        }

        let embInput = try MLDictionaryFeatureProvider(dictionary: [
            "preprocessor_output_1": features,
            "speaker_masks": masks
        ])
        let embOut = try await emb.model.prediction(from: embInput)
        guard let raw = embOut.featureValue(for: "speaker_embeddings")?.multiArrayValue else {
            throw SpeakerEmbedderError.invalidModelOutput("speaker_embeddings missing")
        }
        guard raw.shape.count == 3,
              raw.shape[1].intValue == maskSpeakerSlots,
              raw.shape[2].intValue == outputDim else {
            throw SpeakerEmbedderError.shapeMismatch(
                expected: "[1, \(maskSpeakerSlots), \(outputDim)]",
                got: "\(raw.shape)"
            )
        }
        let rawPtr = raw.dataPointer.bindMemory(to: Float32.self, capacity: raw.count)
        var out = [Float](repeating: 0, count: outputDim)
        for i in 0..<outputDim { out[i] = rawPtr[i] }
        return SpeakerEmbedderHelpers.l2Normalize(out)
    }
}

enum SpeakerEmbedderError: LocalizedError {
    case modelsNotLoaded
    case invalidModelOutput(String)
    case shapeMismatch(expected: String, got: String)

    var errorDescription: String? {
        switch self {
        case .modelsNotLoaded: "Pyannote embedder models not loaded"
        case .invalidModelOutput(let m): "Invalid embedder output: \(m)"
        case .shapeMismatch(let e, let g): "Embedder shape mismatch: expected \(e), got \(g)"
        }
    }
}
