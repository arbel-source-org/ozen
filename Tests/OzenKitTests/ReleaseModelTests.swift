import Foundation
import Testing
@testable import OzenKit

/// Serves assets from memory, in chunks, and remembers every fetch. Its
/// checksum is the byte sum, padded to the shape of a real one, so a
/// manifest can be written for any content.
final class FakeReleaseFetcher: ReleaseFileFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var assets: [String: Data]
    private(set) var fetches: [(asset: String, offset: Int64)] = []
    var refusesResume = false
    var chunk = 5

    init(assets: [String: Data]) {
        self.assets = assets
    }

    static func checksum(_ data: Data) -> String {
        String(format: "%064x", data.reduce(0) { $0 + Int($1) })
    }

    func fetch(_ url: URL, from offset: Int64, appendingTo destination: URL, received: @escaping @Sendable (Int64) -> Void) async throws {
        let asset = url.lastPathComponent
        lock.withLock { fetches.append((asset, offset)) }
        guard let data = lock.withLock({ assets[asset] }) else {
            throw URLError(.fileDoesNotExist)
        }
        var start = Int(offset)
        if offset > 0 && refusesResume {
            try Data().write(to: destination)
            received(-offset)
            start = 0
        }
        if !FileManager.default.fileExists(atPath: destination.path) {
            try Data().write(to: destination)
        }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        try handle.seekToEnd()
        var index = start
        while index < data.count {
            let end = min(index + chunk, data.count)
            try handle.write(contentsOf: data[index..<end])
            received(Int64(end - index))
            index = end
        }
    }

    func sha256(of file: URL) throws -> String {
        Self.checksum(try Data(contentsOf: file))
    }
}

private func temporaryFolder() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ozen-release-\(UUID())", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func manifestData(_ files: [ReleaseModelFile]) -> Data {
    try! JSONEncoder().encode(ReleaseModelManifest(files: files))
}

private func file(_ path: String, asset: String, _ data: Data) -> ReleaseModelFile {
    ReleaseModelFile(path: path, asset: asset, size: Int64(data.count), sha256: FakeReleaseFetcher.checksum(data))
}

@Suite("Release model manifest")
struct ReleaseModelManifestTests {
    private let good = ReleaseModelFile(path: "AudioEncoder.mlpackage/Data/com.apple.CoreML/weights/weight.bin", asset: "AudioEncoder.mlpackage__Data__com.apple.CoreML__weights__weight.bin", size: 12, sha256: String(repeating: "ab", count: 32))

    @Test("a well-formed manifest parses and adds up its bytes")
    func parses() throws {
        let other = ReleaseModelFile(path: "config.json", asset: "config.json", size: 30, sha256: String(repeating: "0", count: 64))
        let manifest = try ReleaseModelManifest.parse(manifestData([good, other]))
        #expect(manifest.files.count == 2)
        #expect(manifest.totalBytes == 42)
    }

    @Test("paths that could escape the model folder are refused")
    func refusesEscapingPaths() {
        for path in ["../elsewhere", "/etc/passwd", "a//b", "./x", "a/../b", ""] {
            var bad = good
            bad.path = path
            #expect(throws: ReleaseModelManifest.ParseFailure.badPath(path)) {
                try ReleaseModelManifest.parse(manifestData([bad]))
            }
        }
    }

    @Test("an asset name with a slash, a zero size, a bad checksum, a duplicate and an empty list are refused")
    func refusesTheRest() {
        var slash = good
        slash.asset = "dir/file"
        #expect(throws: ReleaseModelManifest.ParseFailure.badPath("dir/file")) { try ReleaseModelManifest.parse(manifestData([slash])) }

        var empty = good
        empty.size = 0
        #expect(throws: ReleaseModelManifest.ParseFailure.badSize(good.path)) { try ReleaseModelManifest.parse(manifestData([empty])) }

        var short = good
        short.sha256 = "abc"
        #expect(throws: ReleaseModelManifest.ParseFailure.badChecksum(good.path)) { try ReleaseModelManifest.parse(manifestData([short])) }

        var notHex = good
        notHex.sha256 = String(repeating: "zz", count: 32)
        #expect(throws: ReleaseModelManifest.ParseFailure.badChecksum(good.path)) { try ReleaseModelManifest.parse(manifestData([notHex])) }

        #expect(throws: ReleaseModelManifest.ParseFailure.duplicate(good.path)) { try ReleaseModelManifest.parse(manifestData([good, good])) }
        #expect(throws: ReleaseModelManifest.ParseFailure.noFiles) { try ReleaseModelManifest.parse(manifestData([])) }
        #expect(throws: ReleaseModelManifest.ParseFailure.notJSON) { try ReleaseModelManifest.parse(Data("nope".utf8)) }
    }

    @Test("asset addresses point at GitHub's release download path")
    func assetURL() {
        let url = ReleaseModelURLs.asset(repository: "arbelonson-source/ozen", tag: "model-ivrit-turbo-1", name: "manifest.json")
        #expect(url.absoluteString == "https://github.com/arbelonson-source/ozen/releases/download/model-ivrit-turbo-1/manifest.json")
    }
}

@Suite("Release download plan")
struct ReleaseDownloadPlanTests {
    private let a = ReleaseModelFile(path: "a.bin", asset: "a.bin", size: 100, sha256: String(repeating: "0", count: 64))
    private let b = ReleaseModelFile(path: "sub/b.bin", asset: "sub__b.bin", size: 50, sha256: String(repeating: "0", count: 64))

    @Test("nothing on disk fetches everything from the start")
    func fresh() {
        let steps = ReleaseDownloadPlan.steps(for: ReleaseModelManifest(files: [a, b])) { _ in nil }
        #expect(steps == [ReleaseDownloadStep(file: a, resumeFrom: 0), ReleaseDownloadStep(file: b, resumeFrom: 0)])
    }

    @Test("a whole file is skipped, a cut-off one continues, an oversized one starts over")
    func resumes() {
        let sizes: [String: Int64] = ["a.bin": 100, "sub/b.bin": 20]
        let steps = ReleaseDownloadPlan.steps(for: ReleaseModelManifest(files: [a, b])) { sizes[$0] }
        #expect(steps == [ReleaseDownloadStep(file: b, resumeFrom: 20)])

        let oversized = ReleaseDownloadPlan.steps(for: ReleaseModelManifest(files: [a])) { _ in 101 }
        #expect(oversized == [ReleaseDownloadStep(file: a, resumeFrom: 0)])
    }
}

@Suite("Release model download")
struct ReleaseModelDownloaderTests {
    private let weights = Data((0..<40).map { UInt8($0) })
    private let config = Data("{\"d_model\": 1280}".utf8)

    private func release() -> (files: [ReleaseModelFile], assets: [String: Data]) {
        let files = [
            file("AudioEncoder.mlpackage/Data/com.apple.CoreML/weights/weight.bin", asset: "AudioEncoder.mlpackage__weights__weight.bin", weights),
            file("config.json", asset: "config.json", config),
        ]
        var assets = ["manifest.json": manifestData(files)]
        assets["AudioEncoder.mlpackage__weights__weight.bin"] = weights
        assets["config.json"] = config
        return (files, assets)
    }

    @Test("a fresh download lands every file where the manifest says, with progress climbing to one")
    func fresh() async throws {
        let (_, assets) = release()
        let fetcher = FakeReleaseFetcher(assets: assets)
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let seen = ProgressLog()

        let manifest = try await ReleaseModelDownloader(fetcher: fetcher).download(tag: "m1", into: folder) { seen.record($0) }

        #expect(manifest.files.count == 2)
        #expect(try Data(contentsOf: folder.appendingPathComponent("AudioEncoder.mlpackage/Data/com.apple.CoreML/weights/weight.bin")) == weights)
        #expect(try Data(contentsOf: folder.appendingPathComponent("config.json")) == config)
        let values = seen.values
        #expect(values.first == 0)
        #expect(values.last == 1)
        #expect(values == values.sorted())
        #expect(fetcher.fetches.map(\.asset) == ["manifest.json", "AudioEncoder.mlpackage__weights__weight.bin", "config.json"])
    }

    @Test("a download cut off part way continues from where each file stopped")
    func resumes() async throws {
        let (_, assets) = release()
        let fetcher = FakeReleaseFetcher(assets: assets)
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let partial = folder.appendingPathComponent("AudioEncoder.mlpackage/Data/com.apple.CoreML/weights/weight.bin")
        try FileManager.default.createDirectory(at: partial.deletingLastPathComponent(), withIntermediateDirectories: true)
        try weights.prefix(17).write(to: partial)
        try config.write(to: folder.appendingPathComponent("config.json"))
        let seen = ProgressLog()

        _ = try await ReleaseModelDownloader(fetcher: fetcher).download(tag: "m1", into: folder) { seen.record($0) }

        #expect(try Data(contentsOf: partial) == weights)
        #expect(fetcher.fetches.map(\.asset) == ["manifest.json", "AudioEncoder.mlpackage__weights__weight.bin"])
        #expect(fetcher.fetches.last?.offset == 17)
        // Starts from the bytes already there, not from nothing.
        #expect((seen.values.first ?? 0) > 0.5)
        #expect(seen.values.last == 1)
    }

    @Test("a server that will not resume makes the file start over and still lands it whole")
    func startsOverWhenResumeRefused() async throws {
        let (_, assets) = release()
        let fetcher = FakeReleaseFetcher(assets: assets)
        fetcher.refusesResume = true
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let partial = folder.appendingPathComponent("AudioEncoder.mlpackage/Data/com.apple.CoreML/weights/weight.bin")
        try FileManager.default.createDirectory(at: partial.deletingLastPathComponent(), withIntermediateDirectories: true)
        try weights.prefix(17).write(to: partial)
        let seen = ProgressLog()

        _ = try await ReleaseModelDownloader(fetcher: fetcher).download(tag: "m1", into: folder) { seen.record($0) }

        #expect(try Data(contentsOf: partial) == weights)
        #expect(seen.values.last == 1)
        #expect(seen.values.allSatisfy { $0 >= 0 && $0 <= 1 })
    }

    @Test("a file that arrived whole but wrong is deleted and reported, and the next attempt fetches it again")
    func checksumMismatch() async throws {
        let (_, assets) = release()
        let fetcher = FakeReleaseFetcher(assets: assets)
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let wrong = folder.appendingPathComponent("config.json")
        try Data(repeating: 0x41, count: config.count).write(to: wrong)

        await #expect(throws: ReleaseModelDownloader.Failure.checksumMismatch(path: "config.json")) {
            try await ReleaseModelDownloader(fetcher: fetcher).download(tag: "m1", into: folder) { _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: wrong.path))

        _ = try await ReleaseModelDownloader(fetcher: fetcher).download(tag: "m1", into: folder) { _ in }
        #expect(try Data(contentsOf: wrong) == config)
    }

    @Test("a manifest that can't be trusted stops the download before any file is written")
    func badManifest() async throws {
        let fetcher = FakeReleaseFetcher(assets: ["manifest.json": Data("not json".utf8)])
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        await #expect(throws: ReleaseModelDownloader.Failure.badManifest(.notJSON)) {
            try await ReleaseModelDownloader(fetcher: fetcher).download(tag: "m1", into: folder) { _ in }
        }
        #expect(fetcher.fetches.count == 1)
    }
}

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [Double] = []

    func record(_ value: Double) {
        lock.withLock { log.append(value) }
    }

    var values: [Double] { lock.withLock { log } }
}

@Suite("Catalog folder names for models from a release")
struct CatalogFolderNameTests {
    @Test("a hub model keeps WhisperKit's folder name and a release model its own")
    func folderNames() {
        let hub = WhisperModelOption(variant: "small", displayName: "Small", sizeMB: 1, hebrewQuality: 1, speed: 1, note: "", isRecommended: false)
        #expect(hub.source == .whisperKitHub)
        #expect(hub.folderName == "openai_whisper-small")

        let release = WhisperModelOption(variant: "hebrew", displayName: "Hebrew", sizeMB: 1, hebrewQuality: 1, speed: 1, note: "", isRecommended: false, source: .ozenRelease(tag: "m1"), folderName: "ivrit-ai_whisper")
        #expect(release.folderName == "ivrit-ai_whisper")
    }
}
