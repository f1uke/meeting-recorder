import Foundation

/// Pipeline stages a transcription run progresses through. The actual
/// orchestration lives in `TranscriptionQueue` now; this type only
/// supplies the stage vocabulary + per-stage progress weights so the
/// queue and the UI agree on how to interpret a 0...1 overall fraction.
///
/// Kept under `TranscriptionSession` as a namespace so existing call
/// sites (popover progress bar, queue progress bands) don't churn.
enum TranscriptionSession {
    enum Stage: Equatable, Sendable {
        case loadingModels
        case transcribingMic
        case transcribingOutput
        /// Used when both mic + output run in one combined call (e.g.
        /// `GeminiProvider.transcribeCombinedBatch` pools every stream's
        /// chunks into a single batch). Spans the full mic+output band so
        /// the progress bar moves continuously through the long poll.
        case transcribingBatch
        case merging
        case writing

        var localizedName: String {
            switch self {
            case .loadingModels: "กำลังโหลดโมเดล…"
            case .transcribingMic: "ถอดเสียงไมค์…"
            case .transcribingOutput: "ถอดเสียง meeting + แยกผู้พูด…"
            case .transcribingBatch: "ส่งงาน batch + แยกผู้พูด…"
            case .merging: "รวม timeline…"
            case .writing: "บันทึก transcript…"
            }
        }

        /// Overall-progress band for this stage: `(start, end)` in 0...1.
        /// Tuned to roughly match wall-clock time for a typical meeting on
        /// Apple Silicon — output transcription dominates because it runs
        /// Whisper + SpeakerKit on the longer of the two streams.
        var progressRange: (start: Double, end: Double) {
            switch self {
            case .loadingModels:      return (0.00, 0.02)
            case .transcribingMic:    return (0.02, 0.40)
            case .transcribingOutput: return (0.40, 0.95)
            case .transcribingBatch:  return (0.02, 0.95)
            case .merging:            return (0.95, 0.97)
            case .writing:            return (0.97, 1.00)
            }
        }

        /// Linear ordering used by progress UI strips.
        static let pipeline: [Stage] = [
            .loadingModels, .transcribingMic, .transcribingOutput, .merging, .writing,
        ]
    }

    /// Optional richer status emitted by long-running providers (notably
    /// the Gemini Batch poll loop, which spends 90% of wall time waiting
    /// on Google's backend without the progress fraction moving). UI
    /// renders the summary plus a relative "last check Xs ago" derived
    /// from `updatedAt`. Sibling to `Stage` rather than embedded so
    /// providers can emit it without needing to know the stage.
    struct StageStatus: Sendable, Equatable {
        let updatedAt: Date
        let summary: String

        /// "12s ago" / "2m ago" / "1h 4m ago" — short, monotonic so a
        /// TimelineView re-render every second produces a smooth ticker.
        /// Returns "just now" while the gap rounds to under one second.
        func relativeAgo(now: Date) -> String {
            let delta = max(0, now.timeIntervalSince(updatedAt))
            let total = Int(delta)
            if total < 1 { return "just now" }
            if total < 60 { return "\(total)s ago" }
            let m = total / 60
            let s = total % 60
            if m < 60 { return s == 0 ? "\(m)m ago" : "\(m)m \(s)s ago" }
            let h = m / 60
            let mm = m % 60
            return mm == 0 ? "\(h)h ago" : "\(h)h \(mm)m ago"
        }
    }
}
