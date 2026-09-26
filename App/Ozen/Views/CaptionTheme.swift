import SwiftUI
import OzenKit

/// The three caption looks, resolved to concrete colours. Kept separate
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

    init(_ theme: DisplayPreferences.Theme) {
        switch theme {
        case .dark:
            background = .black
            text = .white
            pendingText = .white.opacity(0.78)
            // About 15:1 on black, like the yellow-on-black theme's text.
            numberText = Color(red: 1.0, green: 0.88, blue: 0.2)
            chrome = .white
            colorScheme = .dark
        case .highContrast:
            background = .black
            text = Color(red: 1.0, green: 0.88, blue: 0.2)
            pendingText = Color(red: 1.0, green: 0.88, blue: 0.2).opacity(0.78)
            // White is the one colour brighter than this yellow on black.
            numberText = .white
            chrome = Color(red: 1.0, green: 0.88, blue: 0.2)
            colorScheme = .dark
        case .light:
            background = .white
            text = .black
            pendingText = .black.opacity(0.7)
            // A deep blue, close to 9:1 on white.
            numberText = Color(red: 0, green: 0.25, blue: 0.7)
            chrome = .black
            colorScheme = .light
        }
    }

    static func name(for theme: DisplayPreferences.Theme) -> String {
        switch theme {
        case .dark: return tr("לבן על שחור", "White on black")
        case .highContrast: return tr("צהוב על שחור", "Yellow on black")
        case .light: return tr("שחור על לבן", "Black on white")
        }
    }
}

extension Color {
    /// The system yellow, orange, green and red read well on black but
    /// fade out on white: yellow on white is about 1.5:1, green about 2:1.
    /// These deeper shades of the same hues (and purple's) stay at least 5:1
    /// against white, which also holds for white words drawn on them.
    /// Any other colour comes back unchanged.
    var deepShade: Color {
        switch self {
        case .yellow: return Color(red: 0.55, green: 0.38, blue: 0)
        case .orange: return Color(red: 0.70, green: 0.30, blue: 0)
        case .green: return Color(red: 0, green: 0.45, blue: 0.15)
        case .red: return Color(red: 0.75, green: 0, blue: 0)
        case .purple: return Color(red: 0.45, green: 0.18, blue: 0.65)
        default: return self
        }
    }

    /// This colour as text or an icon on a `scheme` background: unchanged on
    /// dark backgrounds, the deeper shade on light ones.
    func readable(on scheme: ColorScheme) -> Color {
        scheme == .light ? deepShade : self
    }
}
