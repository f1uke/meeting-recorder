import Foundation
import Combine

/// Orchestrates one dictation utterance: record the mic, transcribe it,
/// paste the text into the frontmost app. A small state machine drives the
/// floating HUD. Owns a dedicated `MicRecorder` + `RMSRingBuffer` so it is
/// fully independent of the meeting-recording pipeline.
@MainActor
final class DictationController: ObservableObject {
    enum DictationState: Equatable {
        case idle
        case listening
        case transcribing
        case injected(String)
        case failed(String)
        case cancelled
    }

    @Published private(set) var state: DictationState = .idle

    /// Live mic levels for the HUD waveform. Owned here so it survives a
    /// recorder restart, mirroring how `RecordingSession` owns its ring.
    let levels = RMSRingBuffer(capacity: 96)

    /// Injected so the controller can refuse to start while a meeting is
    /// being recorded (both drive an `AVAudioEngine` input tap and would
    /// contend for the input device).
    var recordingIsActive: () -> Bool = { false }

    private var recorder: MicRecorder?
    private var tempURL: URL?
    private var silence = SilenceDetector()
    private var silenceTimer: Timer?
    private var sampleClock: TimeInterval = 0

    var isBusy: Bool { state != .idle }

    /// Called on the double-tap trigger. Starts listening when idle (or
    /// after a terminal state), stops + transcribes while listening, and
    /// ignores taps mid-transcribe.
    func toggle() {
        switch state {
        case .idle, .injected, .failed, .cancelled:
            startListening()
        case .listening:
            stopAndTranscribe()
        case .transcribing:
            break
        }
    }

    func startListening() {
        guard isTerminal(state) || state == .idle else { return }
        guard !recordingIsActive() else {
            state = .failed("Can't dictate while recording a meeting")
            autoReset(after: 2.0)
            return
        }
        levels.reset()
        silence = SilenceDetector()
        sampleClock = 0

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dictation-\(UUID().uuidString).m4a")
        tempURL = url

        let rec = MicRecorder()
        let buffer = levels
        let deviceUID = AppPreferences.shared.micDeviceUID
        state = .listening

        // AVAudioEngine.start blocks the calling thread for hundreds of ms,
        // so start off the main actor (see MicRecorder / capture-start note).
        Task.detached(priority: .userInitiated) {
            do {
                try rec.start(url: url, deviceUID: deviceUID, rmsBuffer: buffer)
            } catch {
                // `error` isn't Sendable, so hand the MainActor a String.
                let message = error.localizedDescription
                await MainActor.run { self.failStart(message) }
            }
        }
        recorder = rec
        startSilenceTimer()
    }

    func stopAndTranscribe() {
        guard state == .listening else { return }
        silenceTimer?.invalidate(); silenceTimer = nil

        let rec = recorder
        Task.detached(priority: .userInitiated) { rec?.stop() }
        recorder = nil
        state = .transcribing

        guard let url = tempURL else { state = .idle; return }

        let prefs = AppPreferences.shared
        let config = DictationProviderConfig(
            engine: prefs.dictationEngine,
            geminiKey: prefs.geminiAPIKey,
            geminiModel: prefs.geminiModel.rawValue,
            glossary: prefs.transcriptionGlossary,
            localModel: ModelVariant.largeV3Turbo.rawValue
        )
        let language = prefs.dictationLanguage.whisperCode

        Task {
            do {
                let made = DictationProviderFactory.make(config: config)
                let result = try await made.provider.transcribe(
                    audioURL: url,
                    options: TranscriptionOptions(
                        language: language,
                        withDiarization: false,
                        knownSpeaker: .me,
                        source: .mic,
                        normalizeLoudness: true
                    ),
                    progress: nil
                )
                await made.provider.unloadModels()

                let text = TextInjector.joinSegments(result.segments)
                cleanupTemp()
                if text.isEmpty {
                    state = .failed("Didn't catch that")
                    autoReset(after: 1.8)
                } else {
                    TextInjector.inject(text)
                    state = .injected(text)
                    autoReset(after: 1.2)
                }
            } catch {
                cleanupTemp()
                state = .failed(error.localizedDescription)
                autoReset(after: 3.0)
            }
        }
    }

    func cancel() {
        // Only meaningful while capturing or transcribing.
        guard state == .listening || state == .transcribing else { return }
        silenceTimer?.invalidate(); silenceTimer = nil
        let rec = recorder
        Task.detached(priority: .userInitiated) { rec?.stop() }
        recorder = nil
        cleanupTemp()
        state = .cancelled
        autoReset(after: 0.8)
    }

    // MARK: - Silence auto-stop

    private func startSilenceTimer() {
        silenceTimer?.invalidate()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickSilence() }
        }
        RunLoop.main.add(timer, forMode: .common)
        silenceTimer = timer
    }

    private func tickSilence() {
        guard state == .listening else { return }
        sampleClock += 0.1
        let level = levels.snapshot(last: 1).first ?? 0
        if silence.sample(level: level, at: sampleClock) {
            stopAndTranscribe()
        }
    }

    // MARK: - Helpers

    private func failStart(_ message: String) {
        silenceTimer?.invalidate(); silenceTimer = nil
        recorder = nil
        cleanupTemp()
        state = .failed(message)
        autoReset(after: 3.0)
    }

    private func cleanupTemp() {
        if let url = tempURL { try? FileManager.default.removeItem(at: url) }
        tempURL = nil
    }

    private func isTerminal(_ s: DictationState) -> Bool {
        switch s {
        case .injected, .failed, .cancelled: return true
        default: return false
        }
    }

    private func autoReset(after seconds: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self else { return }
            if self.isTerminal(self.state) { self.state = .idle }
        }
    }
}
