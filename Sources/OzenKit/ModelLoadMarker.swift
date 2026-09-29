import Foundation

public enum ModelLoadMarker {
    public static let fileName = ".ozen-loaded-once"

    public static func hasLoadedBefore(_ folder: URL, system: String) -> Bool {
        guard let recorded = FileManager.default.contents(atPath: folder.appendingPathComponent(fileName).path) else { return false }
        return recorded.isEmpty || String(decoding: recorded, as: UTF8.self) == system
    }

    public static func markLoaded(_ folder: URL, system: String) {
        FileManager.default.createFile(atPath: folder.appendingPathComponent(fileName).path, contents: Data(system.utf8))
    }
}
