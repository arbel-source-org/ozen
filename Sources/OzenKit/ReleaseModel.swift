import Foundation

/// Where a Whisper model's files come from.
public enum WhisperModelSource: Sendable, Equatable {
    /// Argmax's WhisperKit model hub on Hugging Face; WhisperKit fetches it.
    case whisperKitHub
    /// A release of Ozen's own GitHub repository, holding the model's files
    /// as release assets beside a manifest. For models nobody publishes in
    /// WhisperKit's format, such as ivrit.ai's Hebrew-trained Whisper.
    case ozenRelease(tag: String)
}

/// One file of a model published as release assets: where it goes inside
/// the model folder, which asset holds it, and how to know it arrived whole.
public struct ReleaseModelFile: Codable, Sendable, Equatable {
    public var path: String
    public var asset: String
    public var size: Int64
    public var sha256: String

    public init(path: String, asset: String, size: Int64, sha256: String) {
        self.path = path
        self.asset = asset
        self.size = size
        self.sha256 = sha256
    }
}

/// The `manifest.json` asset of a model release: every file of the model.
/// Core ML packages are directories of a few files each, and a release
/// holds flat assets, so the manifest is what turns one back into the other.
public struct ReleaseModelManifest: Codable, Sendable, Equatable {
    public static let assetName = "manifest.json"

    public var files: [ReleaseModelFile]

    public init(files: [ReleaseModelFile]) {
        self.files = files
    }

    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }

    public enum ParseFailure: Error, Equatable {
        case notJSON
        case noFiles
        case badPath(String)
        case badSize(String)
        case badChecksum(String)
        case duplicate(String)
    }

    /// Decodes a manifest and refuses one that could write outside the
    /// model folder or that no download could ever verify.
    public static func parse(_ data: Data) throws -> ReleaseModelManifest {
        guard let manifest = try? JSONDecoder().decode(ReleaseModelManifest.self, from: data) else {
            throw ParseFailure.notJSON
        }
        guard !manifest.files.isEmpty else { throw ParseFailure.noFiles }
        var paths = Set<String>()
        var assets = Set<String>()
        for file in manifest.files {
            let parts = file.path.split(separator: "/", omittingEmptySubsequences: false)
            guard !file.path.isEmpty, !file.path.hasPrefix("/"),
                  !parts.contains(""), !parts.contains("."), !parts.contains("..")
            else { throw ParseFailure.badPath(file.path) }
            guard !file.asset.isEmpty, !file.asset.contains("/") else { throw ParseFailure.badPath(file.asset) }
            guard file.size > 0 else { throw ParseFailure.badSize(file.path) }
            guard file.sha256.count == 64, file.sha256.allSatisfy(\.isHexDigit) else {
                throw ParseFailure.badChecksum(file.path)
            }
            guard paths.insert(file.path).inserted else { throw ParseFailure.duplicate(file.path) }
            guard assets.insert(file.asset).inserted else { throw ParseFailure.duplicate(file.asset) }
        }
        return manifest
    }
}

public enum ReleaseModelURLs {
    /// GitHub's download address for one asset of a release.
    public static func asset(repository: String, tag: String, name: String) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "github.com"
        components.path = "/\(repository)/releases/download/\(tag)/\(name)"
        return components.url!
    }
}

/// One file still to fetch, and where its download continues from.
public struct ReleaseDownloadStep: Sendable, Equatable {
    public var file: ReleaseModelFile
    public var resumeFrom: Int64

    public init(file: ReleaseModelFile, resumeFrom: Int64) {
        self.file = file
        self.resumeFrom = resumeFrom
    }
}

public enum ReleaseDownloadPlan {
    /// What a download cut off part way still has to fetch. A file already
    /// at its full size is skipped here and checked by its checksum at the
    /// end; one larger than it should be is started over.
    public static func steps(for manifest: ReleaseModelManifest, sizeOnDisk: (String) -> Int64?) -> [ReleaseDownloadStep] {
        manifest.files.compactMap { file in
            let onDisk = sizeOnDisk(file.path) ?? 0
            if onDisk == file.size { return nil }
            return ReleaseDownloadStep(file: file, resumeFrom: onDisk < file.size ? onDisk : 0)
        }
    }
}

/// The two things a release download needs from the network and the disk,
/// kept behind a protocol so the download itself is tested here with fakes.
public protocol ReleaseFileFetching: Sendable {
    /// Appends the bytes of `url` from `offset` on to the file at
    /// `destination`, reporting each chunk as it lands. A server that will
    /// not resume from `offset` makes the file start over: the fetcher
    /// truncates it and reports `-offset` once before the first chunk.
    func fetch(_ url: URL, from offset: Int64, appendingTo destination: URL, received: @escaping @Sendable (Int64) -> Void) async throws
    func sha256(of file: URL) throws -> String
}

/// Downloads a model published as release assets into a model folder,
/// file by file, continuing where a cut-off download stopped.
public struct ReleaseModelDownloader: Sendable {
    public static let defaultRepository = "arbelonson-source/ozen"

    public var repository: String
    public var fetcher: any ReleaseFileFetching

    public init(repository: String = ReleaseModelDownloader.defaultRepository, fetcher: any ReleaseFileFetching) {
        self.repository = repository
        self.fetcher = fetcher
    }

    public enum Failure: Error, Equatable {
        case badManifest(ReleaseModelManifest.ParseFailure)
        /// A file that arrived whole but not as published. It has been
        /// deleted, so the next attempt fetches it again.
        case checksumMismatch(path: String)
    }

    /// Fetches (or resumes) every file of the release at `tag` into
    /// `folder`, reporting 0…1 progress by bytes, and returns the manifest.
    /// Every file is checked against its checksum before this returns.
    public func download(
        tag: String,
        into folder: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> ReleaseModelManifest {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)

        let manifestURL = folder.appendingPathComponent(ReleaseModelManifest.assetName)
        try? fileManager.removeItem(at: manifestURL)
        try await fetcher.fetch(assetURL(tag: tag, name: ReleaseModelManifest.assetName), from: 0, appendingTo: manifestURL) { _ in }
        let manifest: ReleaseModelManifest
        do {
            manifest = try ReleaseModelManifest.parse(try Data(contentsOf: manifestURL))
        } catch let failure as ReleaseModelManifest.ParseFailure {
            throw Failure.badManifest(failure)
        }

        let steps = ReleaseDownloadPlan.steps(for: manifest) { path in
            Self.fileSize(folder.appendingPathComponent(path))
        }
        let total = manifest.totalBytes
        let counter = ByteCounter(done: total - steps.reduce(0) { $0 + ($1.file.size - $1.resumeFrom) })
        progress(counter.fraction(of: total))

        for step in steps {
            let destination = folder.appendingPathComponent(step.file.path)
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if step.resumeFrom == 0 {
                try? fileManager.removeItem(at: destination)
            }
            try await fetcher.fetch(assetURL(tag: tag, name: step.file.asset), from: step.resumeFrom, appendingTo: destination) { bytes in
                counter.add(bytes)
                progress(counter.fraction(of: total))
            }
        }

        for file in manifest.files {
            let url = folder.appendingPathComponent(file.path)
            guard Self.fileSize(url) == file.size, try fetcher.sha256(of: url).lowercased() == file.sha256.lowercased() else {
                try? fileManager.removeItem(at: url)
                throw Failure.checksumMismatch(path: file.path)
            }
        }
        progress(1)
        return manifest
    }

    private func assetURL(tag: String, name: String) -> URL {
        ReleaseModelURLs.asset(repository: repository, tag: tag, name: name)
    }

    static func fileSize(_ url: URL) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber
        else { return nil }
        return size.int64Value
    }
}

/// Bytes landed so far, shared with the fetcher's callback.
private final class ByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var done: Int64

    init(done: Int64) {
        self.done = done
    }

    func add(_ bytes: Int64) {
        lock.withLock { done += bytes }
    }

    func fraction(of total: Int64) -> Double {
        guard total > 0 else { return 1 }
        let done = lock.withLock { self.done }
        return min(max(Double(done) / Double(total), 0), 1)
    }
}
