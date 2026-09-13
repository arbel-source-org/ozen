import Foundation

/// Names and words the recognizers should expect. Family members' names
/// are the single biggest source of wrong captions in a home — "אבי"
/// becomes "אבל", "רותי" becomes "רותם" — and both engines accept hints:
/// Apple's recognizer via `contextualStrings`, Whisper via a text prompt
/// the decoder is conditioned on before it hears any audio.
public enum VocabularyHints {
    public static let maximumTerms = 200
    public static let maximumTermLength = 40

    /// Trims, drops empties and duplicates (ignoring case and niqqud),
    /// clips over-long entries and caps the list, keeping first-seen order
    /// so the user's most important names stay at the front — the Whisper
    /// prompt has a token budget and is cut from the end.
    public static func normalized(_ terms: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in terms {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let clipped = String(trimmed.prefix(maximumTermLength))
            let key = HebrewText.normalize(clipped).lowercased()
            guard !key.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(clipped)
            if result.count == maximumTerms { break }
        }
        return result
    }

    /// The text Whisper is primed with. A plain comma-separated list is
    /// what the model was trained to treat as "previous context": it
    /// biases spelling towards these forms without the model trying to
    /// transcribe the prompt itself.
    public static func whisperPrompt(_ terms: [String]) -> String {
        let cleaned = normalized(terms)
        guard !cleaned.isEmpty else { return "" }
        return cleaned.joined(separator: ", ") + "."
    }
}
