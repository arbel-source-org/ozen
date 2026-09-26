import Foundation

/// Keeps the words of a line still being written from flickering.
///
/// Whisper reads the whole sentence again every fraction of a second, and
/// now and then changes its mind about a word near the start and back
/// again; the reader, half way through the line, sees words she already
/// read swap under her eyes. Once two passes in a row agree on how a line
/// begins, that beginning is held: a later pass that changes a word or two
/// in it is shown with the held words, and only what comes after moves.
/// A pass that rewrites much of it, drops words or adds them is a real
/// change of mind and is shown as it is, and so is a word two passes in a
/// row read the new way. The final pass always wins.
public struct LiveAgreement: Sendable, Equatable {
    public static let maximumHeldChanges = 2

    private var lastWords: [String] = []
    private var held: [String] = []

    public init() {}

    /// The text to show for a live pass that read `text`.
    public mutating func settle(_ text: String) -> String {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        defer { lastWords = words }
        guard !words.isEmpty else { return text }

        var shown = words
        var substituted = false
        if words.count >= held.count {
            // Two passes in a row reading the new word are the same
            // agreement that held the old one: "two pills" that became
            // "three pills" twice is a correction, not flicker.
            for index in held.indices where words[index] != held[index]
                && lastWords.indices.contains(index) && lastWords[index] == words[index] {
                held[index] = words[index]
            }
            let changed = held.indices.filter { words[$0] != held[$0] }
            if !changed.isEmpty, changed.count <= Self.maximumHeldChanges, changed.count * 3 <= held.count {
                for index in changed { shown[index] = held[index] }
                substituted = true
            } else if !changed.isEmpty {
                held = Array(held.prefix(changed[0]))
            }
        } else {
            held = Array(zip(held, words).prefix { $0 == $1 }.map(\.0))
        }

        let agreed = zip(lastWords, words).prefix { $0 == $1 }.count
        if agreed > held.count {
            held = Array(shown.prefix(held.count)) + words[held.count..<agreed]
        }
        return substituted ? shown.joined(separator: " ") : text
    }
}
