import XCTest
@testable import Meeting

final class SilenceDetectorTests: XCTestCase {
    func test_silenceBeforeAnySpeech_neverStops() {
        var d = SilenceDetector(threshold: 0.1, silenceToStop: 1.0, minSpeech: 0.3)
        var fired = false
        for i in 0..<30 { fired = fired || d.sample(level: 0.0, at: Double(i) * 0.1) }
        XCTAssertFalse(fired)  // no speech yet, so silence must not trigger
    }

    func test_speechThenSilence_stops() {
        var d = SilenceDetector(threshold: 0.1, silenceToStop: 1.0, minSpeech: 0.3)
        // 0.5s of speech
        for i in 0..<5 { _ = d.sample(level: 0.5, at: Double(i) * 0.1) }
        // then silence; should fire once >= 1.0s elapsed below threshold
        var fired = false
        var t = 0.5
        while t < 1.6 && !fired { fired = d.sample(level: 0.0, at: t); t += 0.1 }
        XCTAssertTrue(fired)
    }

    func test_speechResetsSilenceClock() {
        var d = SilenceDetector(threshold: 0.1, silenceToStop: 1.0, minSpeech: 0.3)
        for i in 0..<5 { _ = d.sample(level: 0.5, at: Double(i) * 0.1) }
        _ = d.sample(level: 0.0, at: 0.5)   // 0.5s silence
        _ = d.sample(level: 0.6, at: 1.3)   // speech again -> resets
        XCTAssertFalse(d.sample(level: 0.0, at: 1.5))  // only 0.2s of new silence
    }
}
