import Foundation

/// Whisper trained on YouTube subtitles inherits a habit of emitting boilerplate
/// strings — "you", "Thank you.", "Subscribe.", "Bye!", music symbols — when
/// it hits a silent or noisy chunk it can't actually decode. These pollute
/// transcripts especially on mic streams where the user is quiet for stretches.
///
/// Filter is intentionally conservative: only drops short segments whose text
/// (after normalization) matches the canonical hallucination set. Real one-word
/// utterances are too short to land in this list anyway since they wouldn't
/// match exactly.
enum HallucinationFilter {
    /// Lowercase, punctuation-stripped text → considered a hallucination.
    /// Add new entries as we observe them in real recordings.
    static let knownPhrases: Set<String> = [
        "you",
        "thanks",
        "thank you",
        "thank you for watching",
        "thanks for watching",
        "subscribe",
        "please subscribe",
        "bye",
        "goodbye",
        "see you",
        "see you next time",
        // Common music/SFX placeholders the model emits for unintelligible audio.
        "♪",
        "♪♪",
        "♪ music ♪",
        "music",
        "applause",
    ]

    /// Returns true if the segment text matches a known boilerplate hallucination
    /// AND is short enough to be plausibly a misfire (not a deliberate utterance
    /// of "thank you" in a real conversation).
    static func isHallucination(text: String, durationSeconds: TimeInterval = 0) -> Bool {
        let normalized = normalize(text)
        if normalized.isEmpty { return true }
        guard knownPhrases.contains(normalized) else { return false }
        // Real "Thank you" in conversation typically spans >= 0.6s. A 1-word
        // hallucination tends to clock under that. When duration is unknown
        // (0), fall back to text-only match — better to over-filter mic noise.
        if durationSeconds <= 0 { return true }
        return durationSeconds < 1.5
    }

    private static func normalize(_ text: String) -> String {
        let lowered = text.lowercased()
        let stripped = lowered.unicodeScalars.filter { scalar in
            // Keep letters, digits, spaces, and the music note glyph; drop punctuation.
            CharacterSet.letters.contains(scalar)
                || CharacterSet.decimalDigits.contains(scalar)
                || scalar == " "
                || scalar == "♪"
        }
        return String(String.UnicodeScalarView(stripped))
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "  ", with: " ")
    }
}
