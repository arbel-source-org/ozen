import Foundation

/// Shapes a caption line's text for reading at large sizes.
///
/// One utterance can hold up to half a minute of someone talking, which at
/// 30 to 60 points is a wall of text where the eye loses its place. Breaking
/// it into short paragraphs at sentence ends gives the reader somewhere to
/// rest and find the newest words. Short lines are left alone, and nothing
/// is ever dropped or reordered: only a space after sentence-ending
/// punctuation can become a line break.
public enum CaptionLayout {
    /// Sentences are gathered until a paragraph would pass this length.
    public static let paragraphCharacters = 90

    public static func readableText(_ text: String, paragraphCharacters: Int = CaptionLayout.paragraphCharacters) -> String {
        let sentences = splitSentences(text)
        guard sentences.count > 1, text.count > paragraphCharacters else { return text }

        var paragraphs: [String] = []
        var current = ""
        for sentence in sentences {
            if current.isEmpty {
                current = sentence
            } else if current.count + 1 + sentence.count <= paragraphCharacters {
                current += " " + sentence
            } else {
                paragraphs.append(current)
                current = sentence
            }
        }
        if !current.isEmpty { paragraphs.append(current) }
        return paragraphs.joined(separator: "\n")
    }

    /// `readableText`, ready to draw: in a right-to-left language each
    /// paragraph starts with an invisible right-to-left mark.
    ///
    /// A paragraph takes its reading direction from its first letter. "OK, az
    /// nitra'e machar" ("OK, see you tomorrow") starts with a Latin one, so it
    /// was laid out left to right, and read from the right it came out as "az
    /// nitra'e machar" followed by "OK": the words in the wrong order. Same for
    /// a line that opens with a name like "WhatsApp". The mark makes Hebrew the
    /// paragraph's direction whatever word comes first. For display only:
    /// copied, shared and spoken text stays as recognized.
    public static func displayText(_ text: String, languageCode: String = "he") -> String {
        directed(readableText(text), languageCode: languageCode)
    }

    /// The marks alone, without breaking the text into paragraphs: for a
    /// one- or two-line preview.
    public static func directed(_ text: String, languageCode: String = "he") -> String {
        guard isRightToLeft(languageCode: languageCode) else { return text }
        return text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { rightToLeftMark + $0 }
            .joined(separator: "\n")
    }

    static let rightToLeftMark = "\u{200F}"

    /// Whether `text` would be laid out left to right on its own: its first
    /// letter (skipping digits, spaces and punctuation, which have no
    /// direction of their own) isn't a right-to-left one.
    static func opensLeftToRight(_ text: String) -> Bool {
        for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
            return !isRightToLeftLetter(scalar)
        }
        return false
    }

    private static func isRightToLeftLetter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF: return true
        default: return false
        }
    }

    static func isRightToLeft(languageCode: String) -> Bool {
        let base = languageCode.split(separator: "-").first.map { String($0).lowercased() } ?? ""
        return ["he", "iw", "yi", "ar", "fa", "ur"].contains(base)
    }

    /// Splits after ".", "?", "!" or "…" (and any closing quote or bracket
    /// right after it) when whitespace follows. "3.5" and "d\"r" ("doctor",
    /// using a gershayim instead of a period) never split, because no space
    /// follows the dot or the gershayim.
    static func splitSentences(_ text: String) -> [String] {
        let enders: Set<Character> = [".", "?", "!", "…"]
        let closers: Set<Character> = ["\"", "'", "”", "’", ")", "]", "״", "׳"]
        var sentences: [String] = []
        var current = ""
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            current.append(character)
            var next = text.index(after: index)
            if enders.contains(character) {
                while next < text.endIndex, enders.contains(text[next]) || closers.contains(text[next]) {
                    current.append(text[next])
                    next = text.index(after: next)
                }
                if next < text.endIndex, text[next].isWhitespace {
                    let trimmed = current.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty { sentences.append(trimmed) }
                    current = ""
                    while next < text.endIndex, text[next].isWhitespace {
                        next = text.index(after: next)
                    }
                }
            }
            index = next
        }
        let tail = current.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { sentences.append(tail) }
        return sentences
    }
}

extension CaptionLayout {
    /// Whether a line shows its speaker's name above it.
    ///
    /// Like a chat, the name appears when the speaker changes, not on every
    /// line: a run of lines by one person reads as one block and leaves more of
    /// the screen for words. A line with no identified speaker shows no label
    /// at all rather than "dover lo yadu'a" ("unknown speaker") on every row.
    public static func showsSpeakerLabel(for segment: TranscriptSegment, after previous: TranscriptSegment?) -> Bool {
        guard let cluster = segment.speakerClusterID else { return false }
        return previous?.speakerClusterID != cluster
    }
}

extension CaptionLayout {
    /// The same rule for a saved conversation, where each line carries the
    /// name it had when it was saved. An unknown-speaker name counts as no
    /// name, so it isn't repeated down the page.
    public static func showsSpeakerLabel(for segment: SavedSegment, after previous: SavedSegment?) -> Bool {
        guard let name = labelName(segment) else { return false }
        return previous.flatMap(labelName) != name
    }

    private static func labelName(_ segment: SavedSegment) -> String? {
        guard let name = segment.speakerName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty,
              name != EmbeddingClusterer.unknownSpeakerName,
              name != "Unknown speaker"
        else { return nil }
        return name
    }
}

extension CaptionLayout {
    /// The lines of a saved conversation that carry a clock time: the first
    /// one, then the first line at least `interval` after the last time
    /// shown. Enough to answer "when did the doctor say that" without a
    /// timestamp cluttering every line.
    public static func timeMarkedLineIDs(in segments: [SavedSegment], interval: TimeInterval = 300) -> Set<UUID> {
        var marked = Set<UUID>()
        var lastShown: TimeInterval?
        for segment in segments {
            if let last = lastShown, segment.startTimestamp - last < interval { continue }
            marked.insert(segment.id)
            lastShown = segment.startTimestamp
        }
        return marked
    }
}
