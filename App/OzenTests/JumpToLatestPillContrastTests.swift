import Testing
@testable import OzenKit

/// `jumpToLatestPill` (App/Ozen/Views/LiveCaptionView.swift) sits over the
/// scrolling transcript on translucent glass with no floor of its own: it
/// depends on a themed tint drawn behind that glass to stay readable no
/// matter what's passing underneath. Can't build the SwiftUI itself here
/// (no macOS/Xcode), so its colours are mirrored as plain sRGB components,
/// the same as CaptionThemeContrastTests.
@Suite("Jump-to-latest pill contrast")
struct JumpToLatestPillContrastTests {
    private let white = (red: 1.0, green: 1.0, blue: 1.0)
    private let black = (red: 0.0, green: 0.0, blue: 0.0)
    private let highContrastYellow = (red: 1.0, green: 0.88, blue: 0.2)
    private let tintAlpha = 0.75

    /// The pill's text/icon colour against its tint, blended over the
    /// worst case something scrolling behind the glass could bleed
    /// through: the opposite extreme from the theme's own background.
    private func worstCaseContrast(
        chrome: (red: Double, green: Double, blue: Double),
        background: (red: Double, green: Double, blue: Double),
        behindGlass: (red: Double, green: Double, blue: Double)
    ) -> Double {
        let tinted = (
            red: background.red * tintAlpha + behindGlass.red * (1 - tintAlpha),
            green: background.green * tintAlpha + behindGlass.green * (1 - tintAlpha),
            blue: background.blue * tintAlpha + behindGlass.blue * (1 - tintAlpha)
        )
        return ContrastRatio.between(chrome, tinted)
    }

    @Test("dark theme: white text/icon stays readable even if pure white bleeds through the glass")
    func dark() {
        #expect(worstCaseContrast(chrome: white, background: black, behindGlass: white) >= 4.5)
    }

    @Test("high-contrast theme: yellow text/icon stays readable even if pure white bleeds through the glass")
    func highContrast() {
        #expect(worstCaseContrast(chrome: highContrastYellow, background: black, behindGlass: white) >= 4.5)
    }

    @Test("light theme: black text/icon stays readable even if pure black bleeds through the glass")
    func light() {
        #expect(worstCaseContrast(chrome: black, background: white, behindGlass: black) >= 4.5)
    }
}
