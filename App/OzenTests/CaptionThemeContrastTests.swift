import Testing
@testable import OzenKit

/// `CaptionTheme` (App/Ozen/Views/CaptionTheme.swift) can't be built or run
/// here — it's SwiftUI, and this machine has no macOS/Xcode — so its
/// colours are mirrored as plain sRGB components rather than resolved from
/// the live `Color` values. If a theme's numbers change there, they need
/// to change here too for this to keep meaning anything; that coupling is
/// the price of pinning WCAG contrast down for a screen this test can't
/// otherwise see.
@Suite("Caption theme contrast")
struct CaptionThemeContrastTests {
    private let white = (red: 1.0, green: 1.0, blue: 1.0)
    private let black = (red: 0.0, green: 0.0, blue: 0.0)
    private let highContrastYellow = (red: 1.0, green: 0.88, blue: 0.2)

    /// An elderly, low-vision reader gets more margin than the bare WCAG
    /// AA minimum (4.5:1 for normal text, 3:1 for large): every theme's
    /// pending (still-being-written) text stays at least AAA-level, 7:1,
    /// against its own background, even though it's deliberately dimmer
    /// than committed text.
    private let minimumPendingTextContrast = 7.0

    @Test("dark theme: pending text (white at 0.78) on black")
    func dark() {
        let ratio = ContrastRatio.ratio(foreground: white, alpha: 0.78, overBackground: black)
        #expect(ratio >= minimumPendingTextContrast)
    }

    @Test("high-contrast theme: pending text (yellow at 0.78) on black")
    func highContrast() {
        let ratio = ContrastRatio.ratio(foreground: highContrastYellow, alpha: 0.78, overBackground: black)
        #expect(ratio >= minimumPendingTextContrast)
    }

    @Test("light theme: pending text (black at 0.7) on white")
    func light() {
        let ratio = ContrastRatio.ratio(foreground: black, alpha: 0.7, overBackground: white)
        #expect(ratio >= minimumPendingTextContrast)
    }
}
