import Foundation

public enum AlertSuggestions {
    public static let names = ["סבתא", "אמא"]
    public static let words = ["סבתא", "אמא", "תרופה", "רופא"]

    public static func label(for word: String, in language: UILanguage) -> String {
        guard language != .hebrew, let meaning = meaning(of: word, in: language) else { return word }
        return "\(meaning) · \(word)"
    }

    static func meaning(of word: String, in language: UILanguage) -> String? {
        switch word {
        case "סבתא": return tr("סבתא", "Grandma", in: language)
        case "אמא": return tr("אמא", "Mom", in: language)
        case "תרופה": return tr("תרופה", "Medicine", in: language)
        case "רופא": return tr("רופא", "Doctor", in: language)
        default: return nil
        }
    }
}
