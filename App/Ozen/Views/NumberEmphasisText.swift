import SwiftUI
import OzenKit

extension Text {
    /// Caption text with its numbers standing out (see `NumberEmphasis`):
    /// heavier, and in `numberColor` when one is given. Everything else
    /// keeps whatever font and colour the caller puts on the `Text`.
    init(caption shown: String, emphasizingNumbers: Bool, size: Double, numberColor: Color?) {
        let ranges = emphasizingNumbers ? NumberEmphasis.ranges(in: shown) : []
        guard !ranges.isEmpty else {
            self.init(shown)
            return
        }
        var attributed = AttributedString(shown)
        for range in ranges {
            guard let lower = AttributedString.Index(range.lowerBound, within: attributed),
                  let upper = AttributedString.Index(range.upperBound, within: attributed)
            else { continue }
            attributed[lower..<upper].font = .system(size: size, weight: .heavy)
            if let numberColor {
                attributed[lower..<upper].foregroundColor = numberColor
            }
        }
        self.init(attributed)
    }
}
