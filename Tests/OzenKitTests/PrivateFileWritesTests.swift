import Foundation
import Testing
@testable import OzenKit

struct PrivateFileWritesTests {
    private func source(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/OzenKit/\(name)"), encoding: .utf8)
    }

    @Test("conversations, settings and the session log are written with iPhone file protection, never a bare atomic write")
    func privateFilesAreProtected() throws {
        #expect(Data.WritingOptions.privateFile.contains(.atomic))
        #expect(Data.WritingOptions.privateFile.contains(.completeFileProtectionUntilFirstUserAuthentication))
        for name in ["TranscriptHistory.swift", "AppSettings.swift", "SessionJournal.swift"] {
            let text = try source(name)
            #expect(!text.contains("options: .atomic)"), "\(name)")
            #expect(text.contains("options: .privateFile)"), "\(name)")
        }
        #expect(try source("SessionJournal.swift").contains("attributes: privateFileAttributes"))
        let journal = try source("SessionJournal.swift")
        #expect(journal.components(separatedBy: "excludeFromBackup(fileURL)").count - 1 == 3)
    }
}
