import Foundation

/// English text (or `%1`/`%2`... template) to its translation, for every
/// language beyond Hebrew and English. Hebrew and English are written
/// directly at each `tr` call site and never consult this table; every
/// other language does, falling back to the English text when a key is
/// missing so the app never shows an empty string or crashes over a gap
/// in translation.
final class TranslationTable: @unchecked Sendable {
    static let shared = TranslationTable()

    private let lock = NSLock()
    private var tablesByLanguage: [String: [String: String]]?

    func lookup(_ english: String, language: UILanguage) -> String? {
        lock.withLock {
            let tables = loadedTables()
            return tables[language.rawValue]?[english]
        }
    }

    /// Exposed for `check-translations.py`'s Swift-side counterpart and for
    /// tests that need to see the raw table, e.g. to confirm a key exists
    /// in every language.
    func table(for language: UILanguage) -> [String: String] {
        lock.withLock { loadedTables()[language.rawValue] ?? [:] }
    }

    private func loadedTables() -> [String: [String: String]] {
        if let tablesByLanguage { return tablesByLanguage }
        let loaded = Self.load()
        tablesByLanguage = loaded
        return loaded
    }

    private static func load() -> [String: [String: String]] {
        guard let url = Bundle.module.url(forResource: "Translations", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: [String: String]].self, from: data)
        else { return [:] }
        return decoded
    }
}
