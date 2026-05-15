import XCTest
@testable import Meeting

final class SpeakerEmbedderHelpersTests: XCTestCase {
    func test_concatenate_joinsSegments() {
        let segs: [[Float]] = [[1, 2, 3], [4, 5], [6]]
        XCTAssertEqual(SpeakerEmbedderHelpers.concatenate(segs), [1, 2, 3, 4, 5, 6])
    }

    func test_concatenate_empty() {
        XCTAssertEqual(SpeakerEmbedderHelpers.concatenate([]), [])
    }

    func test_chunk_5sWindow_05sOverlap() {
        // 10s @ 16kHz = 160_000 samples; chunk 80_000 / hop 72_000
        // → chunk 0 at offset 0, chunk 1 at offset 72_000 (ends at 152_000)
        // Next would be at 144_000 (ends at 224_000 — past 160_000) → drop
        let audio = [Float](repeating: 1.0, count: 160_000)
        let chunks = SpeakerEmbedderHelpers.chunk(audio, chunkSamples: 80_000, hopSamples: 72_000)
        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks[0].count, 80_000)
        XCTAssertEqual(chunks[1].count, 80_000)
    }

    func test_chunk_exactlyOneFull_returnsOne() {
        let audio = [Float](repeating: 1.0, count: 80_000)
        XCTAssertEqual(SpeakerEmbedderHelpers.chunk(audio, chunkSamples: 80_000, hopSamples: 72_000).count, 1)
    }

    func test_chunk_short_returnsEmpty() {
        let audio = [Float](repeating: 1.0, count: 79_999)
        XCTAssertEqual(SpeakerEmbedderHelpers.chunk(audio, chunkSamples: 80_000, hopSamples: 72_000).count, 0)
    }

    func test_l2Normalize_makesUnitVector() {
        let v: [Float] = [3, 4]  // norm = 5
        let u = SpeakerEmbedderHelpers.l2Normalize(v)
        XCTAssertEqual(u[0], 0.6, accuracy: 0.0001)
        XCTAssertEqual(u[1], 0.8, accuracy: 0.0001)
    }

    func test_l2Normalize_zeroVector_returnsZero() {
        let v: [Float] = [0, 0, 0]
        XCTAssertEqual(SpeakerEmbedderHelpers.l2Normalize(v), v)
    }

    func test_cosine_identicalUnitVectors_isOne() {
        let v = SpeakerEmbedderHelpers.l2Normalize([1, 2, 3, 4])
        XCTAssertEqual(SpeakerEmbedderHelpers.cosine(v, v), 1.0, accuracy: 0.0001)
    }

    func test_cosine_orthogonal_isZero() {
        let a: [Float] = [1, 0]
        let b: [Float] = [0, 1]
        XCTAssertEqual(SpeakerEmbedderHelpers.cosine(a, b), 0.0, accuracy: 0.0001)
    }

    func test_cosine_emptyOrMismatch_isZero() {
        XCTAssertEqual(SpeakerEmbedderHelpers.cosine([], []), 0.0)
        XCTAssertEqual(SpeakerEmbedderHelpers.cosine([1, 2], [1, 2, 3]), 0.0)
    }

    func test_cosine_oppositeUnitVectors_isMinusOne() {
        let a = SpeakerEmbedderHelpers.l2Normalize([1, 2, 3, 4])
        let b = SpeakerEmbedderHelpers.l2Normalize([-1, -2, -3, -4])
        XCTAssertEqual(SpeakerEmbedderHelpers.cosine(a, b), -1.0, accuracy: 0.0001)
    }
}
