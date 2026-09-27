import Foundation

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
