import XCTest
@testable import Meeting

/// Unit tests for `CloudAudioPrep.findSilenceCutPoint`. Synthesizes
/// `[Float]` audio arrays with controlled silent / loud regions so we
/// can verify the energy-based VAD without needing real audio files.
final class CloudAudioPrepTests: XCTestCase {
    private let sampleRate = 16000

    /// Build an audio buffer at 16 kHz where every region in `loud`
    /// (closed-open in seconds) is filled with a constant level above
    /// the silence threshold. Everything outside is left at zero.
    private func buildAudio(
        loud: [(start: Double, end: Double)],
        totalDuration: Double,
        level: Float = 0.3
    ) -> [Float] {
        let total = Int(totalDuration * Double(sampleRate))
        var audio = [Float](repeating: 0, count: total)
        for span in loud {
            let s = max(0, Int(span.start * Double(sampleRate)))
            let e = min(total, Int(span.end * Double(sampleRate)))
            guard s < e else { continue }
            for i in s..<e { audio[i] = level }
        }
        return audio
    }

    private func target(seconds: Double) -> Int {
        Int(seconds * Double(sampleRate))
    }

    private var backwardSamples: Int {
        Int(CloudAudioPrep.cutSearchBackward * Double(sampleRate))
    }

    // MARK: - Cases

    func test_picksMidpointOfSilentRun() {
        // 0..30s loud, 30..31s silent, 31..60s loud.
        // Expected cut: midpoint of [30, 31)s = 30.5s.
        let audio = buildAudio(
            loud: [(0, 30), (31, 60)],
            totalDuration: 60
        )
        let t = target(seconds: 30)
        let cut = CloudAudioPrep.findSilenceCutPoint(
            audio: audio,
            searchStart: t - backwardSamples,
            searchEnd: t + backwardSamples,
            fallback: t
        )
        XCTAssertTrue(cut.alignedToSilence)
        // Allow ±1 frame (320 samples) tolerance — frame quantization
        // can shift the run boundaries by up to one frame.
        XCTAssertEqual(cut.sampleIndex, target(seconds: 30.5), accuracy: 320)
    }

    func test_fallsBackWhenNoSilenceInWindow() {
        // Continuous speech across the entire window — no pause to find.
        let audio = buildAudio(loud: [(0, 60)], totalDuration: 60)
        let t = target(seconds: 30)
        let cut = CloudAudioPrep.findSilenceCutPoint(
            audio: audio,
            searchStart: t - backwardSamples,
            searchEnd: t + backwardSamples,
            fallback: t
        )
        XCTAssertFalse(cut.alignedToSilence)
        XCTAssertEqual(cut.sampleIndex, t)
    }

    func test_fallsBackWhenSilenceShorterThanMinimum() {
        // 100 ms silence: shorter than the 200 ms threshold so it must
        // be ignored. Fallback = target.
        let audio = buildAudio(
            loud: [(0, 30), (30.1, 60)],
            totalDuration: 60
        )
        let t = target(seconds: 30)
        let cut = CloudAudioPrep.findSilenceCutPoint(
            audio: audio,
            searchStart: t - backwardSamples,
            searchEnd: t + backwardSamples,
            fallback: t
        )
        XCTAssertFalse(cut.alignedToSilence)
        XCTAssertEqual(cut.sampleIndex, t)
    }

    func test_picksLongestRunWhenMultipleQualify() {
        // Two qualifying pauses: 300 ms before target, 500 ms after.
        // findSilenceCutPoint must pick the longer one (after).
        // 0..25s loud, 25..25.3s silent (300ms), 25.3..32s loud,
        // 32..32.5s silent (500ms), 32.5..60s loud.
        let audio = buildAudio(
            loud: [(0, 25), (25.3, 32), (32.5, 60)],
            totalDuration: 60
        )
        let t = target(seconds: 30)
        let cut = CloudAudioPrep.findSilenceCutPoint(
            audio: audio,
            searchStart: t - backwardSamples,
            searchEnd: t + backwardSamples,
            fallback: t
        )
        XCTAssertTrue(cut.alignedToSilence)
        XCTAssertEqual(cut.sampleIndex, target(seconds: 32.25), accuracy: 320)
    }

    func test_picksSilenceBeforeTargetWhenItIsLonger() {
        // 500 ms silence before target, 300 ms after — must pick before.
        let audio = buildAudio(
            loud: [(0, 25), (25.5, 32), (32.3, 60)],
            totalDuration: 60
        )
        let t = target(seconds: 30)
        let cut = CloudAudioPrep.findSilenceCutPoint(
            audio: audio,
            searchStart: t - backwardSamples,
            searchEnd: t + backwardSamples,
            fallback: t
        )
        XCTAssertTrue(cut.alignedToSilence)
        XCTAssertEqual(cut.sampleIndex, target(seconds: 25.25), accuracy: 320)
    }

    func test_returnsFallbackWhenWindowSmallerThanFrame() {
        // hi - lo < 20 ms (one frame). Helper bails out immediately.
        let audio = buildAudio(loud: [(0, 60)], totalDuration: 60)
        let t = target(seconds: 30)
        let cut = CloudAudioPrep.findSilenceCutPoint(
            audio: audio,
            searchStart: t,
            searchEnd: t + 100,    // 6 ms — less than one 20 ms frame
            fallback: t
        )
        XCTAssertFalse(cut.alignedToSilence)
        XCTAssertEqual(cut.sampleIndex, t)
    }
}
