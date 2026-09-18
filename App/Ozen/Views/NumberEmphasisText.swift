import SwiftUI
import OzenKit

extension Text {
    init(caption shown: String, emphasizingNumbers: Bool, size: Double, numberColor: Color?, uncertainWords: [String] = []) {
        let ranges = emphasizingNumbers ? NumberEmphasis.ranges(in: shown) : []
        let doubtful = UncertainWords.ranges(in: shown, words: uncertainWords)
        guard !ranges.isEmpty || !doubtful.isEmpty else {
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
        for range in doubtful {
            guard let lower = AttributedString.Index(range.lowerBound, within: attributed),
                  let upper = AttributedString.Index(range.upperBound, within: attributed)
            else { continue }
            attributed[lower..<upper].underlineStyle = Text.LineStyle(pattern: .dot)
        }
        self.init(attributed)
    }
}
