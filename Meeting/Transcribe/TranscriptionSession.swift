import Foundation
import Combine

/// Drives transcription for one finished recording. Runs the provider on
/// mic.wav (single speaker = "me") and output.wav (with diarization), merges
/// the two streams chronologically, and writes JSON / Markdown / SRT next to
/// the audio in the meeting folder.
@MainActor
final class TranscriptionSession: ObservableObject {
    enum State: Equatable {
        case idle
        case running(stage: Stage)
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

    /// Run transcription on a finished meeting folder. Expects `mic.wav` and
    /// `output.wav` to exist; produces `transcript.{json,md,srt}` alongside.
    /// `expectedSpeakers` overrides pyannote's auto-detection when set —
    /// pass `1` for solo recordings to suppress over-split.
    func run(meetingFolder: URL, expectedSpeakers: Int? = nil) async {
        state = .running(stage: .loadingModels)

        let micURL = meetingFolder.appendingPathComponent("mic.wav")
        let outputURL = meetingFolder.appendingPathComponent("output.wav")

        defer {
            // Release WhisperKit + SpeakerKit so the multi-GB CoreML weights
            // don't stay resident between recordings. Detached so we can
            // return state to the UI without waiting on actor teardown.
            let provider = self.provider
            Task.detached { await provider.unloadModels() }
        }

        do {
            state = .running(stage: .transcribingMic)
            let mic = try await provider.transcribe(
                audioURL: micURL,
                options: TranscriptionOptions(
                    language: "th",
                    withDiarization: false,
                    knownSpeaker: .me,
                    source: .mic
                )
            )

            state = .running(stage: .transcribingOutput)
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
                )
            )

            state = .running(stage: .merging)
            let merged = TranscriptMerger.merge(mic: mic, output: output)

            state = .running(stage: .writing)
            try TranscriptExporter.writeAll(merged, in: meetingFolder)

            lastResult = merged
            state = .done(transcriptURL: meetingFolder.appendingPathComponent("transcript.md"))
        } catch {
            state = .failed(message: error.localizedDescription)
        }
    }
}
