import Foundation
import Combine

/// Drives transcription for one finished recording. Runs the provider on
/// mic.m4a (single speaker = "me") and output.m4a (with diarization), merges
/// the two streams chronologically, and writes JSON / Markdown / SRT next to
/// the audio in the meeting folder.
@MainActor
final class TranscriptionSession: ObservableObject {
    enum State: Equatable {
        case idle
        /// `overall` is the pre-weighted pipeline progress in 0...1, so the UI
        /// can drive a single bar without knowing about per-stage weights.
        case running(stage: Stage, overall: Double)
        case done(transcriptURL: URL)
        case failed(message: String)
    }

    enum Stage: Equatable {
        case loadingModels
        case transcribingMic
        case transcribingOutput
        case merging
        case writing

        var localizedName: String {
            switch self {
            case .loadingModels: "กำลังโหลดโมเดล…"
            case .transcribingMic: "ถอดเสียงไมค์…"
            case .transcribingOutput: "ถอดเสียง meeting + แยกผู้พูด…"
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
            case .loadingModels:     return (0.00, 0.02)
            case .transcribingMic:   return (0.02, 0.40)
            case .transcribingOutput:return (0.40, 0.95)
            case .merging:           return (0.95, 0.97)
            case .writing:           return (0.97, 1.00)
            }
        }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastResult: MergedTranscript?

    private let provider: TranscriptionProvider

    init(provider: TranscriptionProvider) {
        self.provider = provider
    }

    /// Reset back to idle so the UI returns to the picker. Doesn't cancel a
    /// running task — call this only after `done` or `failed`.
    func dismiss() {
        guard case .running = state else {
            state = .idle
            return
        }
    }

    /// Run transcription on a finished meeting folder. Expects `mic.m4a` and
    /// `output.m4a` to exist; produces `transcript.{json,md,srt}` alongside.
    /// `expectedSpeakers` overrides pyannote's auto-detection when set —
    /// pass `1` for solo recordings to suppress over-split.
    func run(meetingFolder: URL, expectedSpeakers: Int? = nil) async {
        enter(stage: .loadingModels, fraction: 0)

        let micURL = meetingFolder.appendingPathComponent("mic.m4a")
        let outputURL = meetingFolder.appendingPathComponent("output.m4a")

        defer {
            // Release WhisperKit + SpeakerKit so the multi-GB CoreML weights
            // don't stay resident between recordings. Detached so we can
            // return state to the UI without waiting on actor teardown.
            let provider = self.provider
            Task.detached { await provider.unloadModels() }
        }

        do {
            enter(stage: .transcribingMic, fraction: 0)
            let mic = try await provider.transcribe(
                audioURL: micURL,
                options: TranscriptionOptions(
                    language: "th",
                    withDiarization: false,
                    knownSpeaker: .me,
                    source: .mic
                ),
                progress: makeProgressReporter(for: .transcribingMic)
            )

            enter(stage: .transcribingOutput, fraction: 0)
            // Bias toward Thai for the meeting-output stream. Whisper handles
            // Thai-English code-switching well when language is set to "th";
            // leaving it on auto-detect has been observed to fall through to
            // English and butcher Thai content into translated phrasing.
            let output = try await provider.transcribe(
                audioURL: outputURL,
                options: TranscriptionOptions(
                    language: "th",
                    withDiarization: true,
                    knownSpeaker: nil,
                    source: .meetingOutput,
                    expectedSpeakerCount: expectedSpeakers
                ),
                progress: makeProgressReporter(for: .transcribingOutput)
            )

            enter(stage: .merging, fraction: 1)
            let merged = TranscriptMerger.merge(mic: mic, output: output)

            enter(stage: .writing, fraction: 1)
            try TranscriptExporter.writeAll(merged, in: meetingFolder)

            lastResult = merged
            state = .done(transcriptURL: meetingFolder.appendingPathComponent("transcript.md"))
        } catch {
            state = .failed(message: error.localizedDescription)
        }
    }

    private func enter(stage: Stage, fraction: Double) {
        let band = stage.progressRange
        let clamped = max(0, min(1, fraction))
        state = .running(
            stage: stage,
            overall: band.start + (band.end - band.start) * clamped
        )
    }

    /// Build a `@Sendable` reporter that the provider can call from any
    /// task — it hops back to the main actor and only republishes when
    /// the overall fraction has shifted enough to be worth a re-render.
    private nonisolated func makeProgressReporter(
        for stage: Stage
    ) -> (@Sendable (Double) -> Void) {
        return { [weak self] streamFraction in
            Task { @MainActor in
                guard let self else { return }
                guard case .running(let current, let prevOverall) = self.state,
                      current == stage else { return }
                let band = stage.progressRange
                let clamped = max(0, min(1, streamFraction))
                let newOverall = band.start + (band.end - band.start) * clamped
                // Only republish on a >=0.5% delta — keeps SwiftUI from
                // re-rendering the whole popover on every poll tick.
                if abs(newOverall - prevOverall) >= 0.005 || streamFraction >= 1 {
                    self.state = .running(stage: stage, overall: newOverall)
                }
            }
        }
    }
}
