import Foundation
import Accelerate

/// Pure functions used by `SpeakerEmbedder` and `IdentityMatcher`.
///
/// Kept separate so they can be unit-tested without loading Core ML models.
enum SpeakerEmbedderHelpers {
    static func concatenate(_ segments: [[Float]]) -> [Float] {
        var out: [Float] = []
        out.reserveCapacity(segments.reduce(0) { $0 + $1.count })
        for s in segments { out.append(contentsOf: s) }
        return out
    }

    /// Slide a `chunkSamples`-wide window over `audio` with `hopSamples` stride.
    /// Drops trailing tail that's shorter than `chunkSamples`.
    static func chunk(_ audio: [Float], chunkSamples: Int, hopSamples: Int) -> [[Float]] {
        guard audio.count >= chunkSamples else { return [] }
        var chunks: [[Float]] = []
        var start = 0
        while start + chunkSamples <= audio.count {
            chunks.append(Array(audio[start..<(start + chunkSamples)]))
            start += hopSamples
        }
        return chunks
    }

    static func l2Normalize(_ v: [Float]) -> [Float] {
        var sumSq: Float = 0
        vDSP_svesq(v, 1, &sumSq, vDSP_Length(v.count))
        let norm = sqrt(sumSq)
        guard norm > 0 else { return v }
        var divisor = norm
        var out = [Float](repeating: 0, count: v.count)
        vDSP_vsdiv(v, 1, &divisor, &out, 1, vDSP_Length(v.count))
        return out
    }

    /// Cosine similarity for L2-normalized vectors = dot product.
    /// Returns 0 if either vector is empty or sizes mismatch.
    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, a.count > 0 else { return 0 }
        var dot: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        return dot
    }
}
