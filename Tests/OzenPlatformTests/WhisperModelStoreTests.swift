import Testing
@testable import OzenPlatform
import Foundation

@Suite("WhisperModelStore tokenizer cache")
struct WhisperModelStoreTests {
    private func makeStore() throws -> (WhisperModelStore, URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("ozen-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return (WhisperModelStore(downloadBase: base), base)
    }

    private func writeTokenizer(_ contents: String, repo: String, in base: URL) throws -> URL {
        let folder = base.appendingPathComponent("models/openai/\(repo)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("tokenizer.json")
        try Data(contents.utf8).write(to: file)
        return file
    }

    @Test("nothing downloaded yet is not a cached tokenizer")
    func empty() throws {
        let (store, base) = try makeStore()
        defer { try? FileManager.default.removeItem(at: base) }
        #expect(!store.hasCachedTokenizer())
    }

    @Test("a complete tokenizer counts and is kept")
    func valid() throws {
        let (store, base) = try makeStore()
        defer { try? FileManager.default.removeItem(at: base) }
        let file = try writeTokenizer(#"{"model":{"vocab":{}}}"#, repo: "whisper-large-v3", in: base)
        #expect(store.hasCachedTokenizer())
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test("a tokenizer cut off mid-download does not count and is removed for a fresh fetch")
    func truncated() throws {
        let (store, base) = try makeStore()
        defer { try? FileManager.default.removeItem(at: base) }
        let file = try writeTokenizer(#"{"model":{"vocab":{"a"#, repo: "whisper-large-v3", in: base)
        #expect(!store.hasCachedTokenizer())
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test("one good tokenizer is enough, and a broken one beside it is still cleared")
    func mixed() throws {
        let (store, base) = try makeStore()
        defer { try? FileManager.default.removeItem(at: base) }
        let good = try writeTokenizer(#"{"ok":true}"#, repo: "whisper-large-v3", in: base)
        let bad = try writeTokenizer("{", repo: "whisper-small", in: base)
        #expect(store.hasCachedTokenizer())
        #expect(FileManager.default.fileExists(atPath: good.path))
        #expect(!FileManager.default.fileExists(atPath: bad.path))
    }

    @Test("the tokenizer sits where WhisperKit's hub layout looks for it, beside the models")
    func layout() throws {
        let (store, base) = try makeStore()
        defer { try? FileManager.default.removeItem(at: base) }
        #expect(store.tokenizerBase == base)
        #expect(store.modelsRoot.path.hasPrefix(base.appendingPathComponent("models").path))
    }
}
