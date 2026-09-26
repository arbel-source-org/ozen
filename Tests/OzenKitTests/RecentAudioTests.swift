import Foundation
import Testing
@testable import OzenKit

@Suite("Keeping the last half-minute of sound for a marked problem")
struct RecentAudioTests {
    @Test("keeps only the newest samples, oldest first, and a broken sample as silence")
    func ring() {
        var recent = RecentAudio(seconds: 1, sampleRate: 4)
        recent.append([1, 2])
        #expect(recent.samples() == [1, 2])
        recent.append([3, 4, 5])
        #expect(recent.samples() == [2, 3, 4, 5])
        recent.append([6, .nan, 8, 9, 10, 11])
        #expect(recent.samples() == [8, 9, 10, 11])
        recent.append([12, .infinity])
        #expect(recent.samples() == [10, 11, 12, 0])
        recent.clear()
        #expect(recent.samples().isEmpty)
    }

    @Test("a saved clip is a WAV file; only the newest few are kept; nothing is saved from silence never heard")
    func store() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ozen-problem-audio-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProblemAudioStore(directory: directory, keep: 2)
        #expect(store.save([], sampleRate: 16_000, at: Date()) == nil)
        var saved: [URL] = []
        for second in 0..<3 {
            saved.append(try #require(store.save([0.1, -0.1], sampleRate: 16_000, at: Date(timeIntervalSince1970: 1_790_000_000 + Double(second)))))
        }
        let clips = store.clips()
        #expect(clips.map(\.lastPathComponent) == [saved[2], saved[1]].map(\.lastPathComponent))
        let data = try Data(contentsOf: try #require(clips.first))
        #expect(String(decoding: data.prefix(4), as: UTF8.self) == "RIFF")
        #expect(data.count == 44 + 4)
        store.remove(try #require(clips.first))
        #expect(store.clips().count == 1)
    }
}
