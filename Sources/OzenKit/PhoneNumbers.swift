import Foundation

/// Israeli phone numbers written in a caption line, so she can tap one to
/// call it: "050-1234567", "03 123 4567", "+972 50 123 4567". Deliberately
/// narrow. A time, a dose, a price or a date never has the shape (a leading
/// 0 or +972, then 8 or 9 more digits), and iOS asks before it dials, so a
/// wrong match costs one "Cancel".
public enum PhoneNumbers {
    public struct Match: Equatable, Sendable {
        public let range: Range<String.Index>
        /// Digits only, with a leading + for an international number.
        public let dialable: String

        public var url: URL? { URL(string: "tel:" + dialable) }
    }

    public static func matches(in text: String) -> [Match] {
        guard let pattern else { return [] }
        let whole = NSRange(text.startIndex..., in: text)
        return pattern.matches(in: text, range: whole).compactMap { found in
            guard let range = Range(found.range, in: text) else { return nil }
            let written = text[range]
            let digits = written.filter(\.isASCIIDigit)
            if written.hasPrefix("+") {
                guard digits.hasPrefix("972"), (11...12).contains(digits.count) else { return nil }
                return Match(range: range, dialable: "+" + digits)
            }
            guard (9...10).contains(digits.count) else { return nil }
            return Match(range: range, dialable: String(digits))
        }
    }

    /// A leading 0 or +972, a second digit that isn't 0 or 1 (no Israeli
    /// number continues that way, which keeps "01/02/2026" out), then
    /// digits with at most one dash or space between any two. Not glued
    /// to more digits or a + on either side.
    private static let pattern = try? NSRegularExpression(
        pattern: #"(?<![\d+])(?:\+972[- ]?|0)[2-9](?:[- ]?\d){7,8}(?!\d)"#
    )
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
