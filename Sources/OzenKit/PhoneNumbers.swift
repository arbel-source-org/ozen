import Foundation

public enum PhoneNumbers {
    public struct Match: Equatable, Sendable {
        public let range: Range<String.Index>
        public let dialable: String

        public var url: URL? { URL(string: "tel:" + dialable) }
    }

    public static func matches(in text: String) -> [Match] {
        guard let pattern, let servicePattern else { return [] }
        let whole = NSRange(text.startIndex..., in: text)
        let services: [Match] = servicePattern.matches(in: text, range: whole).compactMap { found in
            guard let range = Range(found.range, in: text) else { return nil }
            let written = text[range]
            return Match(range: range, dialable: String(written.filter(\.isASCIIDigit)))
        }
        let phones: [Match] = pattern.matches(in: text, range: whole).compactMap { found in
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
        return (services + phones).sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    private static let pattern = try? NSRegularExpression(
        pattern: #"(?<![\d+])(?:\+972[- ]?|0)[2-9](?:[- ]?\d){7,8}(?!\d)"#
    )

    private static let servicePattern = try? NSRegularExpression(
        pattern: #"(?<![\d+*])1[- ]?(?:700|800|801|599)(?:[- ]?\d){6}(?!\d)"#
    )
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
