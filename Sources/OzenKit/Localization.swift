import Foundation

public enum UILanguage: String, Codable, Sendable, CaseIterable {
    case hebrew
    case english

    public var isRightToLeft: Bool { self == .hebrew }

    public static func forSpeaking(_ text: String, otherwise fallback: UILanguage) -> UILanguage {
        let scalars = text.unicodeScalars
        if scalars.contains(where: { (0x0590...0x05FF).contains($0.value) }) { return .hebrew }
        if scalars.contains(where: { ("a"..."z").contains($0) || ("A"..."Z").contains($0) }) { return .english }
        return fallback
    }
}

public enum AppLanguage: String, Codable, Sendable, CaseIterable {
    case system
    case hebrew
    case english

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

public func tr(_ hebrew: String, _ english: String) -> String {
    tr(hebrew, english, in: Localization.language)
}

public func tr(_ hebrew: String, _ english: String, in language: UILanguage) -> String {
    switch language {
    case .hebrew: return hebrew
    case .english: return english
    }
}
