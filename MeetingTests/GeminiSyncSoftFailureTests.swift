import XCTest
@testable import Meeting

/// The sync chunk fan-out must substitute a visible placeholder when a
/// single chunk soft-fails (MAX_TOKENS truncation or a safety block),
/// matching the batch parsers — one degenerate chunk must not kill the
/// rest of the transcript. Hard errors (network, auth, cancellation)
/// must still propagate so the job genuinely fails.
final class GeminiSyncSoftFailureTests: XCTestCase {

    // MARK: - Soft failures → placeholder

    func test_syncPlaceholder_outputTruncated_substitutesMaxTokensPlaceholder() {
        let error = TranscriptionError.providerFailed(
            "Gemini", underlying: GeminiError.outputTruncated
        )
        let seg = GeminiProvider.syncPlaceholder(for: error, offset: 120, chunkEnd: 180)
        XCTAssertNotNil(seg)
        XCTAssertEqual(seg?.start, 120)
        XCTAssertEqual(seg?.end, 180)
        XCTAssertEqual(seg?.text, "[Gemini ข้ามท่อนนี้: MAX_TOKENS]")
        XCTAssertNil(seg?.language)
    }

    func test_syncPlaceholder_contentBlocked_substitutesReasonPlaceholder() {
        let error = TranscriptionError.providerFailed(
            "Gemini", underlying: GeminiError.contentBlocked(reason: "RECITATION")
        )
        let seg = GeminiProvider.syncPlaceholder(for: error, offset: 0, chunkEnd: 60)
        XCTAssertEqual(seg?.text, "[Gemini ข้ามท่อนนี้: RECITATION]")
    }

    // MARK: - Hard errors → nil (caller re-throws)

    func test_syncPlaceholder_generateFailed_returnsNil() {
        let error = TranscriptionError.providerFailed(
            "Gemini", underlying: GeminiError.generateFailed("HTTP 500")
        )
        XCTAssertNil(GeminiProvider.syncPlaceholder(for: error, offset: 0, chunkEnd: 60))
    }

    func test_syncPlaceholder_uploadFailed_returnsNil() {
        let error = TranscriptionError.providerFailed(
            "Gemini", underlying: GeminiError.uploadFailed("connection reset")
        )
        XCTAssertNil(GeminiProvider.syncPlaceholder(for: error, offset: 0, chunkEnd: 60))
    }

    func test_syncPlaceholder_nonProviderError_returnsNil() {
        XCTAssertNil(GeminiProvider.syncPlaceholder(
            for: CancellationError(), offset: 0, chunkEnd: 60
        ))
        XCTAssertNil(GeminiProvider.syncPlaceholder(
            for: TranscriptionError.modelLoadFailed("no key"), offset: 0, chunkEnd: 60
        ))
    }
}
