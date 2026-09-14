import Foundation

/// The language the app's own words are in: buttons, settings, status
/// lines, notifications. Captions are in whatever language people speak.
public enum UILanguage: String, Codable, Sendable, CaseIterable {
    case hebrew
    case english

    public var isRightToLeft: Bool { self == .hebrew }
}

/// The choice in Settings: follow the phone, or always one language.
public enum AppLanguage: String, Codable, Sendable, CaseIterable {
    case system
    case hebrew
    case english

    /// Hebrew when the phone's first language is Hebrew, English for any
    /// other language: the two the app is written in, and English is the
    /// one more people read.
    public func resolved(preferredLanguages: [String]) -> UILanguage {
        switch self {
        case .hebrew: return .hebrew
        case .english: return .english
        case .system:
            guard let first = preferredLanguages.first?.lowercased() else { return .hebrew }
            return first.hasPrefix("he") || first.hasPrefix("iw") ? .hebrew : .english
        }
    }
}

/// Which language `tr` picks. Set once at launch and whenever the setting
/// changes. Hebrew until then, which is what tests expect.
///
/// A test that wants English binds `override` for its own task instead of
/// changing the shared value, so tests running side by side don't see
/// each other's language.
public enum Localization {
    @TaskLocal public static var override: UILanguage?

    public static var language: UILanguage {
        get { override ?? store.value }
        set { store.value = newValue }
    }

    private static let store = LanguageStore()
}

private final class LanguageStore: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = UILanguage.hebrew

    var value: UILanguage {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// The app's words in the language in use: `tr("הגדרות", "Settings")`.
/// Both versions sit side by side where the text is used, so neither can
/// be forgotten or drift out of step with the other.
public func tr(_ hebrew: String, _ english: String) -> String {
    tr(hebrew, english, in: Localization.language)
}

public func tr(_ hebrew: String, _ english: String, in language: UILanguage) -> String {
    switch language {
    case .hebrew: return hebrew
    case .english: return english
    }
}
