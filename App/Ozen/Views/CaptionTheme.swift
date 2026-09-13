import SwiftUI
import OzenKit

/// The three caption looks, resolved to concrete colours. Kept separate
/// from `DisplayPreferences` (OzenKit, platform-free) because SwiftUI's
/// `Color` doesn't exist there.
struct CaptionTheme {
    let background: Color
    let text: Color
    let pendingText: Color
    let chrome: Color
    let colorScheme: ColorScheme

    init(_ theme: DisplayPreferences.Theme) {
        switch theme {
        case .dark:
            background = .black
            text = .white
            pendingText = .white.opacity(0.62)
            chrome = .white
            colorScheme = .dark
        case .highContrast:
            background = .black
            text = Color(red: 1.0, green: 0.88, blue: 0.2)
            pendingText = Color(red: 1.0, green: 0.88, blue: 0.2).opacity(0.6)
            chrome = Color(red: 1.0, green: 0.88, blue: 0.2)
            colorScheme = .dark
        case .light:
            background = .white
            text = .black
            pendingText = .black.opacity(0.55)
            chrome = .black
            colorScheme = .light
        }
    }

    var displayName: String { "" }

    static func name(for theme: DisplayPreferences.Theme) -> String {
        switch theme {
        case .dark: return "לבן על שחור"
        case .highContrast: return "צהוב על שחור"
        case .light: return "שחור על לבן"
        }
    }
}
