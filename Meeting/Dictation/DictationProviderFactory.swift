import Foundation

/// Which backend transcribes a dictation utterance. Independent of the
/// meeting-recording `TranscriptionEngine` so the user can pick, e.g.,
/// cloud Gemini for quick dictation while meetings stay local (or vice
/// versa).
enum DictationEngine: String, CaseIterable, Identifiable, Sendable {
    case gemini
    case local

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .gemini: "Gemini 2.5 Pro (cloud)"
        case .local:  "Local (WhisperKit turbo)"
        }
    }

    var description: String {
        switch self {
        case .gemini:
            "Highest quality on Thai-English. Sends the short clip to Google, so it needs an API key and a network round-trip (a few seconds)."
        case .local:
            "Runs entirely on-device with the fast turbo model. Near-instant once warm, fully private, slightly lower accuracy."
        }
    }
}

/// Immutable snapshot of the settings a dictation transcribe needs, taken
/// on the MainActor and passed to the pure factory so provider selection
/// stays unit-testable and free of `AppPreferences.shared`.
struct DictationProviderConfig: Sendable {
    let engine: DictationEngine
    let geminiKey: String
    let geminiModel: String
    let glossary: String
    let localModel: String
}

/// Builds the `TranscriptionProvider` for a single dictation utterance from
/// a config snapshot. Falls back to the local model when Gemini is selected
/// but no API key is configured, so dictation still works offline instead
/// of erroring on every utterance.
enum DictationProviderFactory {
    static func make(config: DictationProviderConfig) -> (provider: TranscriptionProvider, engineDidFallBack: Bool) {
        switch config.engine {
        case .gemini where !config.geminiKey.isEmpty:
            // Dictation is a single speaker (the user): keep it Gemini-only
            // with no diarization, which removes SpeakerKit latency and its
            // failure surface on short mono mic clips.
            let p = GeminiProvider(
                apiKey: config.geminiKey,
                glossary: config.glossary,
                modelName: config.geminiModel,
                useBatchAPI: false,
                diarizationEnabled: false
            )
            return (p, false)
        case .gemini:
            return (LocalProvider(modelVariant: config.localModel), true)
        case .local:
            return (LocalProvider(modelVariant: config.localModel), false)
        }
    }
}
