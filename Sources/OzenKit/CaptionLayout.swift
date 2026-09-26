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
            .map { rightToLeftMark + anchorTrailingPunctuation(String($0)) }
            .joined(separator: "\n")
    }

    static let rightToLeftMark = "\u{200F}"

    /// Neutral punctuation ending a right-to-left paragraph (UAX #9) takes
    /// its direction from the run before it. After a Latin word or a
    /// digit ("WhatsApp.", "Acamol!") that resolves left to right, so the
    /// mark visually jumps to the wrong side of those characters instead
    /// of staying at the line's true end. A trailing mark, flanking the
    /// punctuation with right-to-left context on both sides, anchors it
    /// where it belongs.
    private static func anchorTrailingPunctuation(_ line: String) -> String {
        let neutralEnders: Set<Character> = [".", "!", "?", ")", ":"]
        guard let last = line.last, neutralEnders.contains(last) else { return line }
        var beforeMarks = line.endIndex
        while beforeMarks > line.startIndex, neutralEnders.contains(line[line.index(before: beforeMarks)]) {
            beforeMarks = line.index(before: beforeMarks)
        }
        guard beforeMarks > line.startIndex else { return line }
        let character = line[line.index(before: beforeMarks)]
        guard character.isLetter || character.isNumber,
              let scalar = character.unicodeScalars.first, !isRightToLeftLetter(scalar)
        else { return line }
        return line + rightToLeftMark
    }

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
    /// How many of the newest lines the caption screen draws. A phone left
    /// listening on the nightstand for days collects thousands, and every
    /// word arriving made the screen go over all of them again. Nobody
    /// scrolls back through hundreds of lines on the live screen; older
    /// ones are in the saved conversations.
    public static let onScreenLineLimit = 300

    /// Where the lines drawn on the caption screen start.
    public static func firstOnScreenIndex(lineCount: Int) -> Int {
        max(0, lineCount - onScreenLineLimit)
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
        // After a quiet stretch the time is drawn between the lines, and
        // the name heads the new run again.
        return previous?.speakerClusterID != cluster || startsAfterQuiet(segment, previous: previous)
    }

    /// A quiet stretch this long between two lines puts the later line's
    /// clock time between them, so a sentence from half an hour ago isn't
    /// read as the one before the words just said.
    public static let quietGapSeconds: TimeInterval = 5 * 60

    /// Whether `segment` began `quietGapSeconds` or more after `previous`
    /// last changed.
    public static func startsAfterQuiet(_ segment: TranscriptSegment, previous: TranscriptSegment?) -> Bool {
        guard let previous else { return false }
        return segment.startTimestamp - previous.lastUpdateTimestamp >= quietGapSeconds
    }
}

extension CaptionLayout {
    /// The same rule for a saved conversation, where each line carries the
    /// name it had when it was saved. An unknown-speaker name counts as no
    /// name, so it isn't repeated down the page.
    public static func showsSpeakerLabel(for segment: SavedSegment, after previous: SavedSegment?) -> Bool {
        guard let name = labelName(segment) else { return false }
        return previous.flatMap(labelName) != name || startsAfterQuiet(for: segment, previous: previous)
    }

    /// The saved-history version of `startsAfterQuiet(_:previous:)`: a
    /// `SavedSegment` only ever kept its start time, not the live segment's
    /// last-update time, so the gap is measured between the two start times.
    public static func startsAfterQuiet(for segment: SavedSegment, previous: SavedSegment?) -> Bool {
        guard let previous else { return false }
        return segment.startTimestamp - previous.startTimestamp >= quietGapSeconds
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
