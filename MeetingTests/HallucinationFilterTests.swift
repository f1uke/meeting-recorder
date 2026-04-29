import XCTest
@testable import Meeting

final class HallucinationFilterTests: XCTestCase {
    func test_emptyText_isHallucination() {
        XCTAssertTrue(HallucinationFilter.isHallucination(text: ""))
        XCTAssertTrue(HallucinationFilter.isHallucination(text: "   "))
        XCTAssertTrue(HallucinationFilter.isHallucination(text: ".  ."))
    }

    func test_canonicalShortPhrases_areHallucinations() {
        for phrase in ["you", "You.", "Thank you.", "thanks for watching",
                       "Subscribe!", "Bye", "♪"] {
            XCTAssertTrue(
                HallucinationFilter.isHallucination(text: phrase, durationSeconds: 0.8),
                "should drop: \(phrase)"
            )
        }
    }

    func test_longUtterances_arePreservedEvenIfMatchingPhrase() {
        // Real "thank you" in conversation — at 2.5s span, plausibly genuine.
        XCTAssertFalse(
            HallucinationFilter.isHallucination(
                text: "Thank you.", durationSeconds: 2.5
            )
        )
    }

    func test_realThaiContent_isPreserved() {
        let samples = [
            "สวัสดีครับ ทดสอบหนึ่ง สอง สาม",
            "การที่เราสั่งเป็นสมมุติว่ามันเป็นพินล็อก",
            "We need to verify the biometric",
            "facts biometrics allow ของ enter"
        ]
        for s in samples {
            XCTAssertFalse(
                HallucinationFilter.isHallucination(text: s, durationSeconds: 3.0),
                "should keep: \(s)"
            )
        }
    }

    func test_zeroDuration_dropsKnownHallucinationsRegardless() {
        // When duration is unknown (0), be conservative and drop.
        XCTAssertTrue(
            HallucinationFilter.isHallucination(text: "you", durationSeconds: 0)
        )
    }

    func test_punctuationAndCase_areNormalized() {
        XCTAssertTrue(HallucinationFilter.isHallucination(text: "Thank you!", durationSeconds: 0.5))
        XCTAssertTrue(HallucinationFilter.isHallucination(text: "THANK YOU.", durationSeconds: 0.5))
        XCTAssertTrue(HallucinationFilter.isHallucination(text: "  thank you  ", durationSeconds: 0.5))
    }
}
