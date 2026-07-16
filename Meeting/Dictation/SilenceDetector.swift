import Foundation

/// Pure decision helper: fires an auto-stop once the user has spoken
/// (at least `minSpeech` cumulative seconds above `threshold`) and then
/// gone quiet for `silenceToStop` continuous seconds. Kept value-typed
/// and AppKit-free so it can be driven from tests without real audio.
struct SilenceDetector {
    let threshold: Float
    let silenceToStop: TimeInterval
    let minSpeech: TimeInterval

    private var speechAccum: TimeInterval = 0
    private var silenceStart: TimeInterval?
    private var lastT: TimeInterval?
    private var hasSpoken = false

    init(threshold: Float = 0.08, silenceToStop: TimeInterval = 1.5, minSpeech: TimeInterval = 0.3) {
        self.threshold = threshold
        self.silenceToStop = silenceToStop
        self.minSpeech = minSpeech
    }

    /// Feed one normalized RMS `level` (0...1) sampled at time `t` seconds.
    /// Returns true exactly when auto-stop should trigger.
    mutating func sample(level: Float, at t: TimeInterval) -> Bool {
        let dt = lastT.map { max(0, t - $0) } ?? 0
        lastT = t

        if level >= threshold {
            speechAccum += dt
            if speechAccum >= minSpeech { hasSpoken = true }
            silenceStart = nil
            return false
        }

        // Below threshold.
        guard hasSpoken else { return false }
        if silenceStart == nil { silenceStart = t }
        if let s = silenceStart, t - s >= silenceToStop {
            return true
        }
        return false
    }
}
