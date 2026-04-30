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
}
