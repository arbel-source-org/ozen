import SwiftUI
import OzenKit

/// The caption looks, resolved to concrete colours. Kept separate
/// from `DisplayPreferences` (OzenKit, platform-free) because SwiftUI's
/// `Color` doesn't exist there.
struct CaptionTheme {
    let background: Color
    let text: Color
    let pendingText: Color
    /// Numbers in a finished line (see `NumberEmphasis`): a second colour
    /// as easy to read on the background as the text itself.
    let numberText: Color
    let chrome: Color
    let colorScheme: ColorScheme
    /// What the screen asks the system for. Nil for "match the phone": the
    /// look is worked out from the phone's own scheme, and forcing that
    /// scheme back would pin it there, so it never followed the phone again.
    let preferredScheme: ColorScheme?
    /// Behind cards on the caption screen. Doubled with the system's
    /// Increase Contrast on, where a 10% tint barely shows an edge.
    let cardFill: Double

    /// `system` is the phone's own light/dark scheme and `contrast` its
    /// Increase Contrast setting, both from the SwiftUI environment. With
    /// Increase Contrast on, words still being heard are drawn as strongly
    /// as finished ones instead of dimmed.
    init(_ theme: DisplayPreferences.Theme, system: ColorScheme = .dark, contrast: ColorSchemeContrast = .standard) {
        let resolved: DisplayPreferences.Theme = theme == .matchPhone ? (system == .light ? .light : .dark) : theme
        let increased = contrast == .increased
        cardFill = increased ? 0.2 : 0.1
        switch resolved {
        case .dark, .matchPhone:
            background = .black
            text = .white
            pendingText = increased ? .white : .white.opacity(0.78)
            // About 15:1 on black, like the yellow-on-black theme's text.
            numberText = Color(red: 1.0, green: 0.88, blue: 0.2)
            chrome = .white
            colorScheme = .dark
        case .highContrast:
            background = .black
            text = Color(red: 1.0, green: 0.88, blue: 0.2)
            pendingText = increased ? Color(red: 1.0, green: 0.88, blue: 0.2) : Color(red: 1.0, green: 0.88, blue: 0.2).opacity(0.78)
            // White is the one colour brighter than this yellow on black.
            numberText = .white
            chrome = Color(red: 1.0, green: 0.88, blue: 0.2)
            colorScheme = .dark
        case .light:
            background = .white
            text = .black
            pendingText = increased ? .black : .black.opacity(0.7)
            // A deep blue, close to 9:1 on white.
            numberText = Color(red: 0, green: 0.25, blue: 0.7)
            chrome = .black
            colorScheme = .light
        }
        preferredScheme = theme == .matchPhone ? nil : colorScheme
    }

    static func name(for theme: DisplayPreferences.Theme) -> String {
        switch theme {
        case .dark: return tr("לבן על שחור", "White on black")
        case .highContrast: return tr("צהוב על שחור", "Yellow on black")
        case .light: return tr("שחור על לבן", "Black on white")
        case .matchPhone: return tr("כמו בטלפון (בהיר או כהה)", "Match the phone (light or dark)")
        }
    }
}

extension Color {
    /// The system yellow, orange, green and red read well on black but
    /// fade out on white: yellow on white is about 1.5:1, green about 2:1.
    /// These deeper shades of the same hues (and purple's and blue's) stay at least 5:1
    /// against white, which also holds for white words drawn on them.
    /// Any other colour comes back unchanged.
    nonisolated var deepShade: Color {
        switch self {
        case .yellow: return Color(red: 0.55, green: 0.38, blue: 0)
        case .orange: return Color(red: 0.70, green: 0.30, blue: 0)
        case .green: return Color(red: 0, green: 0.45, blue: 0.15)
        case .red: return Color(red: 0.75, green: 0, blue: 0)
        case .purple: return Color(red: 0.45, green: 0.18, blue: 0.65)
        case .blue: return Color(red: 0, green: 0.32, blue: 0.75)
        // The system's secondary grey is see-through: under white text it
        // showed whatever was behind the banner.
        case .secondary: return Color(white: 0.3)
        default: return self
        }
    }

    /// This colour as text or an icon on a `scheme` background: unchanged on
    /// dark backgrounds, the deeper shade on light ones.
    nonisolated func readable(on scheme: ColorScheme) -> Color {
        scheme == .light ? deepShade : self
    }
}
