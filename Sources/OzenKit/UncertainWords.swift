import Foundation

/// Which words of a caption line to mark as doubtful.
///
/// A mark on the whole line says "something here may be wrong" without
/// saying what; someone who can't hear the room has no way to tell whether
/// it was the hour of the appointment or the "thank you" after it. Whisper
/// gives a probability for every piece of a word it writes, so the doubt
/// can be put on the word itself.
public enum UncertainWords {
    /// A word counts as doubtful when the model's average probability for
    /// its pieces is under this. Stricter than the line's 0.4
    /// (`CaptionConfidence.uncertainBelow`): one word's score swings far
    /// more than a line's average, and the first piece of any word is often
    /// a toss-up between good candidates.
    public static let uncertainBelow: Float = 0.25
    /// A line where most words are marked says nothing a line mark doesn't.
    public static let maximumShare = 0.5

    /// The doubtful ones among `words`, given the log-probabilities of each
    /// word's pieces, as the normalized words `ranges` looks for.
    public static func pick(words: [String], logprobs: [[Float]]) -> [String] {
        var picked: [String] = []
        var counted = 0
        for (word, pieces) in zip(words, logprobs) {
            let key = normalize(word)
            guard !key.isEmpty else { continue }
            counted += 1
            let finite = pieces.filter(\.isFinite)
            guard !finite.isEmpty else { continue }
            let mean = finite.reduce(0, +) / Float(finite.count)
            if exp(mean) < uncertainBelow, !picked.contains(key) {
                picked.append(key)
            }
        }
        guard counted > 0, Double(picked.count) / Double(counted) <= maximumShare else { return [] }
        return picked
    }

    /// Where the doubtful words sit in `text`, whole words only.
    public static func ranges(in text: String, words: [String]) -> [Range<String.Index>] {
        guard !words.isEmpty else { return [] }
        let wanted = Set(words)
        var ranges: [Range<String.Index>] = []
        var index = text.startIndex
        while index < text.endIndex {
            guard !text[index].isWhitespace else {
                index = text.index(after: index)
                continue
            }
            let end = text[index...].firstIndex(where: \.isWhitespace) ?? text.endIndex
            if wanted.contains(normalize(String(text[index..<end]))) {
                ranges.append(index..<end)
            }
            index = end
        }
        return ranges
    }

    static func normalize(_ word: String) -> String {
        WhisperResultFilter.normalize(word)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}
