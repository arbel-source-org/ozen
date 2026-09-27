import Foundation

public enum UILanguage: String, Codable, Sendable, CaseIterable {
    case hebrew
    case english
    case arabic
    case russian
    case amharic
    case french
    case spanish
    case ukrainian
    case german
    case portuguese
    case chineseSimplified
    case hindi

    public var isRightToLeft: Bool { self == .hebrew || self == .arabic }

    /// Which voice should read `text` aloud, from its letters. A script
    /// only one app language uses decides by itself; Cyrillic picks
    /// Ukrainian when it has letters Russian lacks; Latin letters keep the
    /// app's language when that is written in Latin letters (a French
    /// phrase gets the French voice), and are English otherwise. Text with
    /// no letters at all (a time, a number) follows the app's language.
    public static func forSpeaking(_ text: String, otherwise fallback: UILanguage) -> UILanguage {
        let values = text.unicodeScalars.map(\.value)
        func has(_ ranges: ClosedRange<UInt32>...) -> Bool {
            values.contains { value in ranges.contains { $0.contains(value) } }
        }
        if has(0x0590...0x05FF) { return .hebrew }
        if has(0x0600...0x06FF, 0x0750...0x077F, 0xFB50...0xFDFF, 0xFE70...0xFEFF) { return .arabic }
        if has(0x1200...0x139F, 0x2D80...0x2DDF) { return .amharic }
        if has(0x0900...0x097F) { return .hindi }
        if has(0x3400...0x4DBF, 0x4E00...0x9FFF) { return .chineseSimplified }
        if has(0x0400...0x04FF) {
            if fallback == .ukrainian || text.contains(where: { "іїєґІЇЄҐ".contains($0) }) { return .ukrainian }
            return .russian
        }
        if values.contains(where: { (0x41...0x5A).contains($0) || (0x61...0x7A).contains($0) || (0xC0...0x24F).contains($0) }) {
            return fallback.writesInLatinLetters ? fallback : .english
        }
        return fallback
    }

    var writesInLatinLetters: Bool {
        switch self {
        case .english, .french, .spanish, .german, .portuguese: return true
        default: return false
        }
    }

    /// Dates and weekdays in this language, however the phone is set.
    var formattingLocale: Locale {
        Locale(identifier: self == .chineseSimplified ? "zh-Hans" : languageCode.identifier)
    }

    /// The code the phone's voice list is searched with.
    public var speechVoiceCode: String {
        switch self {
        case .hebrew: return "he-IL"
        case .english: return "en-US"
        case .arabic: return "ar-SA"
        case .russian: return "ru-RU"
        case .amharic: return "am-ET"
        case .french: return "fr-FR"
        case .spanish: return "es-ES"
        case .ukrainian: return "uk-UA"
        case .german: return "de-DE"
        case .portuguese: return "pt-PT"
        case .chineseSimplified: return "zh-CN"
        case .hindi: return "hi-IN"
        }
    }

    /// The two-letter code the platform's locale APIs expect. Simplified
    /// Chinese also needs the "Hans" script, since "zh" alone is ambiguous
    /// between scripts.
    var languageCode: Locale.LanguageCode {
        switch self {
        case .hebrew: return "he"
        case .english: return "en"
        case .arabic: return "ar"
        case .russian: return "ru"
        case .amharic: return "am"
        case .french: return "fr"
        case .spanish: return "es"
        case .ukrainian: return "uk"
        case .german: return "de"
        case .portuguese: return "pt"
        case .chineseSimplified: return "zh"
        case .hindi: return "hi"
        }
    }

    var script: Locale.Script? {
        self == .chineseSimplified ? "Hans" : nil
    }

    /// Every language's own name for itself, for the Settings picker: a
    /// reader picks "العربية" by recognizing it, not by reading English or
    /// Hebrew about it.
    public var nativeName: String {
        switch self {
        case .hebrew: return "עברית"
        case .english: return "English"
        case .arabic: return "العربية"
        case .russian: return "Русский"
        case .amharic: return "አማርኛ"
        case .french: return "Français"
        case .spanish: return "Español"
        case .ukrainian: return "Українська"
        case .german: return "Deutsch"
        case .portuguese: return "Português"
        case .chineseSimplified: return "简体中文"
        case .hindi: return "हिन्दी"
        }
    }

    public func locale(keepingRegionOf base: Locale) -> Locale {
        var components = Locale.Components(locale: base)
        components.languageComponents = Locale.Language.Components(
            languageCode: languageCode,
            script: script,
            region: base.region
        )
        return Locale(components: components)
    }

    /// Matches a phone preferred-language tag (`"pt-BR"`, `"zh-Hans-US"`,
    /// `"iw"`...) to a supported language by its leading subtag, ignoring
    /// script and region. `nil` when nothing supported matches.
    static func match(languageTag: String) -> UILanguage? {
        let code = languageTag.lowercased().split(separator: "-").first.map(String.init) ?? languageTag.lowercased()
        switch code {
        case "he", "iw": return .hebrew
        case "en": return .english
        case "ar": return .arabic
        case "ru": return .russian
        case "am": return .amharic
        case "fr": return .french
        case "es": return .spanish
        case "uk": return .ukrainian
        case "de": return .german
        case "pt": return .portuguese
        case "zh": return .chineseSimplified
        case "hi": return .hindi
        default: return nil
        }
    }
}

public enum AppLanguage: String, Codable, Sendable, CaseIterable {
    case system
    case hebrew
    case english
    case arabic
    case russian
    case amharic
    case french
    case spanish
    case ukrainian
    case german
    case portuguese
    case chineseSimplified
    case hindi

    /// `.system` walks the phone's preferred languages in order and uses
    /// the first one a supported language matches; Hebrew is the fallback
    /// when none of them do, same as before there was a choice at all.
    public func resolved(preferredLanguages: [String]) -> UILanguage {
        switch self {
        case .system:
            for tag in preferredLanguages {
                if let match = UILanguage.match(languageTag: tag) { return match }
            }
            return .hebrew
        case .hebrew: return .hebrew
        case .english: return .english
        case .arabic: return .arabic
        case .russian: return .russian
        case .amharic: return .amharic
        case .french: return .french
        case .spanish: return .spanish
        case .ukrainian: return .ukrainian
        case .german: return .german
        case .portuguese: return .portuguese
        case .chineseSimplified: return .chineseSimplified
        case .hindi: return .hindi
        }
    }
}

public enum Localization {
    @TaskLocal public static var override: UILanguage?

    public static var language: UILanguage {
        get { override ?? store.value }
        set { store.value = newValue }
    }

    public static var locale: Locale { language.locale(keepingRegionOf: .current) }

    private static let store = LanguageStore()
}

public extension Date {
    func formatted(inAppLanguage date: Date.FormatStyle.DateStyle, time: Date.FormatStyle.TimeStyle) -> String {
        formatted(Date.FormatStyle(date: date, time: time, locale: Localization.locale))
    }
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
    default: return TranslationTable.shared.lookup(english, language: language) ?? english
    }
}

/// For a string built from `\(...)` interpolation, which can't be looked up
/// by its finished text: `hebrewTemplate`/`englishTemplate` hold `%1`,
/// `%2`... in place of each value, and `args` gives those values in that
/// order (as text; the caller interpolates them the same way it always
/// did). The translation table is keyed by `englishTemplate`, same as the
/// plain `tr`, so a translated template can freely reorder its placeholders
/// for its own grammar without touching the call site.
public func tr(_ hebrewTemplate: String, _ englishTemplate: String, args: [String]) -> String {
    tr(hebrewTemplate, englishTemplate, args: args, in: Localization.language)
}

public func tr(_ hebrewTemplate: String, _ englishTemplate: String, args: [String], in language: UILanguage) -> String {
    let template: String
    switch language {
    case .hebrew: template = hebrewTemplate
    case .english: template = englishTemplate
    default: template = TranslationTable.shared.lookup(englishTemplate, language: language) ?? englishTemplate
    }
    return substitutingPlaceholders(in: template, with: args)
}

/// Replaces `%1`, `%2`... with `args[0]`, `args[1]`... Walked from the
/// highest number down so `%10` (if it ever comes up) isn't half-eaten by
/// a `%1` replacement first.
private func substitutingPlaceholders(in template: String, with args: [String]) -> String {
    var result = template
    for index in stride(from: args.count, through: 1, by: -1) {
        result = result.replacingOccurrences(of: "%\(index)", with: args[index - 1])
    }
    return result
}
