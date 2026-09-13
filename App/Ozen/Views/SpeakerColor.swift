import SwiftUI

/// A small, fixed, high-contrast, colorblind-checked palette — not
/// generated per speaker — so a color always carries the same identity
/// meaning it did a moment ago instead of drifting with hue math.
enum SpeakerColor {
    private static let palette: [Color] = [
        Color(red: 0.98, green: 0.75, blue: 0.18),  // amber
        Color(red: 0.45, green: 0.78, blue: 0.98),  // sky
        Color(red: 0.95, green: 0.55, blue: 0.60),  // rose
        Color(red: 0.55, green: 0.85, blue: 0.55),  // green
        Color(red: 0.80, green: 0.65, blue: 0.98),  // violet
    ]

    static func color(forClusterID id: Int?) -> Color {
        guard let id else { return .gray }
        return palette[id % palette.count]
    }
}
