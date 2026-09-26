import SwiftUI
import OzenKit

/// A small, fixed, colorblind-checked palette — not generated per
/// speaker — so a color always carries the same identity meaning it did a
/// moment ago instead of drifting with hue math.
enum SpeakerColor {
    /// For the dark themes: 9-12.5:1 against black.
    private static let palette: [Color] = [
        Color(red: 0.98, green: 0.75, blue: 0.18),  // amber
        Color(red: 0.45, green: 0.78, blue: 0.98),  // sky
        Color(red: 0.95, green: 0.55, blue: 0.60),  // rose
        Color(red: 0.55, green: 0.85, blue: 0.55),  // green
        Color(red: 0.80, green: 0.65, blue: 0.98),  // violet
    ]

    /// The same hues in the same order for the white theme, where the
    /// pastels above fall to 1.7-2.3:1 and a name is barely there: 5.8-7:1.
    private static let deepPalette: [Color] = [
        Color(red: 0.55, green: 0.36, blue: 0.0),   // amber
        Color(red: 0.0, green: 0.36, blue: 0.62),   // sky
        Color(red: 0.70, green: 0.15, blue: 0.25),  // rose
        Color(red: 0.10, green: 0.45, blue: 0.15),  // green
        Color(red: 0.42, green: 0.25, blue: 0.70),  // violet
    ]

    static func color(forClusterID id: Int?, speakerName: String? = nil, on scheme: ColorScheme) -> Color {
        guard id != nil || speakerName != nil else { return scheme == .light ? Color(white: 0.4) : .gray }
        let colors = scheme == .light ? deepPalette : palette
        if let speakerName, !TranscriptSessionSummary.isGenericLabel(speakerName) {
            return colors[stableIndex(speakerName, count: colors.count)]
        }
        guard let id else { return scheme == .light ? Color(white: 0.4) : .gray }
        return colors[id % colors.count]
    }

    private static func stableIndex(_ name: String, count: Int) -> Int {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in name.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return Int(hash % UInt64(count))
    }
}
