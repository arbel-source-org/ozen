import Foundation
import Testing
@testable import OzenKit

@Suite("SessionJournal")
struct SessionJournalTests {
    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ozen-journal-\(UUID())", isDirectory: true)
            .appendingPathComponent("journal.log")
    }

    @Test("what one run of the app wrote is there for the next one to read")
    func survivesRelaunch() {
        let url = temporaryFile()
        let first = SessionJournal(fileURL: url)
        first.append("listening", at: 1_800_000_000)
        first.append("microphone stopped delivering audio", at: 1_800_000_065.5)

        let second = SessionJournal(fileURL: url)
        second.append("app started", at: 1_800_000_100)

        #expect(second.entries().map(\.text) == ["listening", "microphone stopped delivering audio", "app started"])
        #expect(second.entries()[1].at == 1_800_000_065.5)
    }

    @Test("lines carry the day as well as the time, at her clock")
    func reportLines() {
        let journal = SessionJournal(fileURL: temporaryFile())
        journal.append("listening", at: 1_800_000_000)
        #expect(journal.reportLines(utcOffsetSeconds: 3 * 3_600) == ["2027-01-15 11:00:00 listening"])
    }

    @Test("an error that runs to paragraphs stays one line, and a short one")
    func longText() {
        let journal = SessionJournal(fileURL: temporaryFile())
        journal.append("first\nsecond\tthird " + String(repeating: "x", count: 2_000), at: 1)
        let entries = journal.entries()
        #expect(entries.count == 1)
        #expect(entries[0].text.hasPrefix("first second third x"))
        #expect(entries[0].text.count <= SessionJournal.textLimit + 1)
    }

    @Test("months of lines never grow the file without end: the oldest go")
    func trims() throws {
        let url = temporaryFile()
        let journal = SessionJournal(fileURL: url)
        let text = String(repeating: "y", count: 300)
        for index in 0..<1_000 {
            journal.append("\(index) \(text)", at: TimeInterval(index))
        }
        let entries = journal.entries()
        #expect(entries.last?.text.hasPrefix("999 ") == true)
        #expect(entries.count >= 100)
        let size = try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        #expect(size <= SessionJournal.maximumBytes + 1_000)
    }

    @Test("a file someone damaged loses the bad lines, not the rest")
    func damagedFile() throws {
        let url = temporaryFile()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("garbage\n12.00\tkept\n\tno time\n".utf8).write(to: url)
        #expect(SessionJournal(fileURL: url).entries() == [SessionJournal.Entry(at: 12, text: "kept")])
    }

    @Test("a burst of a thousand appends all still show up, in order, once asked for")
    func bufferedBurstIsComplete() {
        let journal = SessionJournal(fileURL: temporaryFile())
        for index in 0..<1_000 {
            journal.append("line \(index)", at: TimeInterval(index))
        }
        let entries = journal.entries()
        #expect(entries.count == 1_000)
        #expect(entries.first?.text == "line 0")
        #expect(entries.last?.text == "line 999")
    }

    @Test("a fresh append sits buffered in memory rather than touching disk right away; entries() flushes it and sees it immediately regardless")
    func bufferedUntilAskedFor() {
        let url = temporaryFile()
        let journal = SessionJournal(fileURL: url)
        journal.append("not on disk yet", at: 1)
        // Comfortably shorter than SessionJournal.flushDelay: the file
        // must not have been written this soon after a single append.
        Thread.sleep(forTimeInterval: 0.05)
        let onDiskAlready = (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        #expect(!onDiskAlready.contains("not on disk yet"), "a single fresh append should be buffered, not hit disk immediately")
        #expect(journal.entries().map(\.text) == ["not on disk yet"], "entries() must flush and see it right away regardless of the buffering delay")
    }
}
