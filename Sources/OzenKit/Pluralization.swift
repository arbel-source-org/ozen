import Foundation

/// The CLDR plural bucket a count falls into for a given language. Hebrew
/// and English keep their own dedicated logic elsewhere; this exists for
/// the other ten interface languages, each of which groups counts by its
/// own grammar rather than a single "singular or plural" split.
enum PluralCategory {
    case zero, one, two, few, many, other
}

/// `n`'s plural category in `language`, by the CLDR rule for that
/// language. Fractional counts never appear here, so `.other` is only
/// reached where a language's rule has no bucket for a given `n mod 100`.
func pluralCategory(for n: Int, in language: UILanguage) -> PluralCategory {
    let mod10 = n % 10
    let mod100 = n % 100
    switch language {
    case .hebrew, .english:
        return n == 1 ? .one : .other
    case .russian, .ukrainian:
        if mod10 == 1, mod100 != 11 { return .one }
        if (2...4).contains(mod10), !(12...14).contains(mod100) { return .few }
        return .many
    case .arabic:
        if n == 0 { return .zero }
        if n == 1 { return .one }
        if n == 2 { return .two }
        if (3...10).contains(mod100) { return .few }
        if (11...99).contains(mod100) { return .many }
        return .other
    case .french, .hindi, .amharic:
        return (n == 0 || n == 1) ? .one : .other
    case .spanish, .german, .portuguese:
        return n == 1 ? .one : .other
    case .chineseSimplified:
        return .other
    }
}

/// `word`, with `n` in front unless `omitNumeral` says the language
/// already carries the count in the word itself (Arabic's bare singular
/// and dual for one and two).
func countedPhrase(_ n: Int, word: String, omitNumeral: Bool) -> String {
    omitNumeral ? word : "\(n) \(word)"
}

/// Whether `language` folds the count into the word itself for
/// `category`, rather than showing a numeral (Arabic's bare "دقيقة" for
/// one, "دقيقتان" for two).
func omitsNumeral(_ category: PluralCategory, in language: UILanguage) -> Bool {
    language == .arabic && (category == .one || category == .two)
}

/// Minute and hour words for the ten languages with only generic plural
/// handling (no quarter/half phrasing, unlike Hebrew's `minutesText`).
enum TimeUnitWord {
    static func minute(_ category: PluralCategory, in language: UILanguage) -> String {
        switch language {
        case .russian:
            switch category {
            case .one: return "минута"
            case .few: return "минуты"
            default: return "минут"
            }
        case .ukrainian:
            switch category {
            case .one: return "хвилина"
            case .few: return "хвилини"
            default: return "хвилин"
            }
        case .arabic:
            switch category {
            case .one: return "دقيقة"
            case .two: return "دقيقتان"
            case .few: return "دقائق"
            default: return "دقيقة"
            }
        case .french:
            return category == .one ? "minute" : "minutes"
        case .spanish:
            return category == .one ? "minuto" : "minutos"
        case .german:
            return category == .one ? "Minute" : "Minuten"
        case .portuguese:
            return category == .one ? "minuto" : "minutos"
        case .hindi:
            return "मिनट"
        case .amharic:
            return "ደቂቃ"
        case .chineseSimplified:
            return "分钟"
        case .hebrew, .english:
            return category == .one ? "minute" : "minutes"
        }
    }

    static func second(_ category: PluralCategory, in language: UILanguage) -> String {
        switch language {
        case .russian:
            switch category {
            case .one: return "секунда"
            case .few: return "секунды"
            default: return "секунд"
            }
        case .ukrainian:
            switch category {
            case .one: return "секунда"
            case .few: return "секунди"
            default: return "секунд"
            }
        case .arabic:
            switch category {
            case .one: return "ثانية"
            case .two: return "ثانيتان"
            case .few: return "ثوانٍ"
            default: return "ثانية"
            }
        case .french:
            return category == .one ? "seconde" : "secondes"
        case .spanish:
            return category == .one ? "segundo" : "segundos"
        case .german:
            return category == .one ? "Sekunde" : "Sekunden"
        case .portuguese:
            return category == .one ? "segundo" : "segundos"
        case .hindi:
            return "सेकंड"
        case .amharic:
            return "ሰከንድ"
        case .chineseSimplified:
            return "秒"
        case .hebrew, .english:
            return category == .one ? "second" : "seconds"
        }
    }

    static func hour(_ category: PluralCategory, in language: UILanguage) -> String {
        switch language {
        case .russian:
            switch category {
            case .one: return "час"
            case .few: return "часа"
            default: return "часов"
            }
        case .ukrainian:
            switch category {
            case .one: return "година"
            case .few: return "години"
            default: return "годин"
            }
        case .arabic:
            switch category {
            case .one: return "ساعة"
            case .two: return "ساعتان"
            case .few: return "ساعات"
            default: return "ساعة"
            }
        case .french:
            return category == .one ? "heure" : "heures"
        case .spanish:
            return category == .one ? "hora" : "horas"
        case .german:
            return category == .one ? "Stunde" : "Stunden"
        case .portuguese:
            return category == .one ? "hora" : "horas"
        case .hindi:
            return category == .one ? "घंटा" : "घंटे"
        case .amharic:
            return "ሰዓት"
        case .chineseSimplified:
            return "小时"
        case .hebrew, .english:
            return category == .one ? "hour" : "hours"
        }
    }

    /// Rounded down to nothing worth counting ("less than a minute").
    static func lessThanAMinute(in language: UILanguage) -> String {
        switch language {
        case .russian: return "меньше минуты"
        case .ukrainian: return "менше хвилини"
        case .arabic: return "أقل من دقيقة"
        case .french: return "moins d'une minute"
        case .spanish: return "menos de un minuto"
        case .german: return "weniger als eine Minute"
        case .portuguese: return "menos de um minuto"
        case .hindi: return "एक मिनट से कम"
        case .amharic: return "ከአንድ ደቂቃ በታች"
        case .chineseSimplified: return "不到一分钟"
        case .hebrew, .english: return "less than a minute"
        }
    }
}
