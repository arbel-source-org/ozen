import Foundation

/// WCAG 2 contrast, worked out from plain component values so it can be
/// checked without SwiftUI (which doesn't exist in OzenKit) or a device:
/// callers resolve their own colours to sRGB components and hand them here.
public enum ContrastRatio {
    /// The ratio between two sRGB colours, each `red`/`green`/`blue` in
    /// 0...1. 4.5:1 is WCAG AA for normal-size text, 3:1 for large text;
    /// higher is more readable. Order of the two colours doesn't matter.
    public static func between(
        _ first: (red: Double, green: Double, blue: Double),
        _ second: (red: Double, green: Double, blue: Double)
    ) -> Double {
        let firstLuminance = relativeLuminance(first)
        let secondLuminance = relativeLuminance(second)
        let lighter = max(firstLuminance, secondLuminance)
        let darker = min(firstLuminance, secondLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    /// One colour, `alpha` of the way from `background` to `foreground`
    /// (simple alpha compositing, the way a translucent colour is drawn
    /// over a solid one), then its contrast against that same background.
    public static func ratio(
        foreground: (red: Double, green: Double, blue: Double),
        alpha: Double,
        overBackground background: (red: Double, green: Double, blue: Double)
    ) -> Double {
        let blended = (
            red: foreground.red * alpha + background.red * (1 - alpha),
            green: foreground.green * alpha + background.green * (1 - alpha),
            blue: foreground.blue * alpha + background.blue * (1 - alpha)
        )
        return between(blended, background)
    }

    private static func relativeLuminance(_ color: (red: Double, green: Double, blue: Double)) -> Double {
        0.2126 * linearized(color.red) + 0.7152 * linearized(color.green) + 0.0722 * linearized(color.blue)
    }

    private static func linearized(_ channel: Double) -> Double {
        channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
    }
}
