import XCTest
import AVFoundation
import WhisperKit
@testable import Meeting

/// Regression tests for the dictation runtime failure (PR #3 follow-up).
///
/// Root cause: `DictationController.stopAndTranscribe` fired `rec.stop()` on
/// a detached task WITHOUT awaiting it, then transcribed immediately.
/// `MicRecorder.stop()` is what finalizes the AAC/m4a (releasing the
/// `AVAudioFile` flushes the encoder + writes the moov atom). Reading the
/// file before that finalize fails to decode, surfacing as a `providerFailed`
/// error in the HUD ("Provider Gemini (...) + SpeakerKit ผิดพลาด: ...").
final class DictationTranscribeHandoffTests: XCTestCase {
    /// The invariant the controller must respect: an m4a is only decodable
    /// AFTER the writing `AVAudioFile` is released (finalized). This is why
    /// `stopAndTranscribe` must await the recorder stop before transcribing.
    func test_m4aOnlyDecodesAfterFinalize() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("handoff-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }

        let sampleRate = 48000.0
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        var file: AVAudioFile? = try AVAudioFile(
            forWriting: url, settings: settings,
            commonFormat: .pcmFormatFloat32, interleaved: false
        )
        let frames = AVAudioFrameCount(sampleRate)  // ~1s
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
        buf.frameLength = frames
        let ptr = buf.floatChannelData![0]
        for i in 0..<Int(frames) {
            ptr[i] = 0.3 * sinf(2 * .pi * 220 * Float(i) / Float(sampleRate))
        }
        try file!.write(from: buf)

        // Before finalize: decode must NOT yield the full audio (throws or empty).
        var beforeCount = 0
        var beforeThrew = false
        do {
            beforeCount = try AudioProcessor.loadAudioAsFloatArray(
                fromPath: url.path(percentEncoded: false), channelMode: .sumChannels(nil)).count
        } catch {
            beforeThrew = true
        }
        XCTAssertTrue(beforeThrew || beforeCount == 0,
                      "unfinalized m4a must not decode to usable audio (this is the race)")

        // Finalize (what MicRecorder.stop does) then decode succeeds.
        file = nil
        let after = try AudioProcessor.loadAudioAsFloatArray(
            fromPath: url.path(percentEncoded: false), channelMode: .sumChannels(nil))
        XCTAssertGreaterThan(after.count, 0, "finalized m4a must decode")
    }
}

/// Locks the "dictation is Gemini-only, no diarization" contract.
final class GeminiProviderDictationModeTests: XCTestCase {
    func test_diarizationDisabled_dropsSpeakerKitFromName() {
        let p = GeminiProvider(apiKey: "k", glossary: "", modelName: "gemini-2.5-pro",
                               useBatchAPI: false, diarizationEnabled: false)
        XCTAssertEqual(p.name, "Gemini (gemini-2.5-pro)")
        XCTAssertFalse(p.name.contains("SpeakerKit"))
    }

    func test_diarizationEnabled_default_keepsSpeakerKitForMeetings() {
        let p = GeminiProvider(apiKey: "k", glossary: "", modelName: "gemini-2.5-pro")
        XCTAssertTrue(p.name.contains("+ SpeakerKit"))
    }

    func test_factory_buildsNonDiarizingGeminiForDictation() {
        let cfg = DictationProviderConfig(engine: .gemini, geminiKey: "k",
                                          geminiModel: "gemini-2.5-pro", glossary: "",
                                          localModel: "large-v3-turbo")
        let made = DictationProviderFactory.make(config: cfg)
        XCTAssertFalse(made.provider.name.contains("SpeakerKit"),
                       "dictation must not carry the diarization surface")
    }
}

/// The HUD failure copy must be the concise underlying cause, not the
/// meeting-oriented "Provider ... ผิดพลาด" wrapper.
final class DictationErrorMessageTests: XCTestCase {
    func test_providerFailed_unwrapsToUnderlying() {
        let underlying = GeminiError.generateFailed("boom")
        let wrapped = TranscriptionError.providerFailed("Gemini (gemini-2.5-pro)", underlying: underlying)
        XCTAssertEqual(DictationController.humanMessage(for: wrapped),
                       underlying.localizedDescription)
    }

    func test_modelLoadFailed_showsRawMessage_notDoubleWrapped() {
        // The associated value is already a full sentence (e.g. "Gemini API
        // key not set. ..."); wrapping it in "โหลดโมเดล ... ไม่ได้" would
        // garble it, so the HUD shows the raw message.
        let e = TranscriptionError.modelLoadFailed("Gemini API key not set.")
        XCTAssertEqual(DictationController.humanMessage(for: e), "Gemini API key not set.")
    }
}
