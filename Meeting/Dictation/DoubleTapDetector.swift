import Foundation

/// Pure timing state machine for detecting a "double-tap" of a key: two
/// key-down transitions within `window` seconds, with no intervening
/// other input. Kept free of AppKit / CGEvent so it is unit-testable and
/// the event-tap layer only has to translate raw events into calls here.
struct DoubleTapDetector {
    /// Max seconds between the two taps to count as a double-tap.
    var window: TimeInterval

    /// Timestamp of the pending first tap, or nil when disarmed.
    private var firstTapAt: TimeInterval?

    init(window: TimeInterval = 0.4) {
        self.window = window
    }

    /// Register a control-key press at `t` (seconds, monotonic). Returns
    /// true when it completes a valid double-tap; the detector then resets
    /// so a third press starts a fresh pair.
    mutating func controlPressed(at t: TimeInterval) -> Bool {
        if let first = firstTapAt, t - first <= window, t >= first {
            firstTapAt = nil
            return true
        }
        // Too slow, or no pending tap: this press becomes the new first tap.
        firstTapAt = t
        return false
    }

    /// Any non-control input (another key, or a different modifier) breaks
    /// the pending pair so chords like Ctrl-C never masquerade as a tap.
    mutating func otherInputHappened() {
        firstTapAt = nil
    }
}
