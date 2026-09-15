import CoreML
import Foundation
@preconcurrency import WhisperKit
import OzenKit

/// Where Whisper models live on the device and how they get there. Both
/// the engine (which needs a folder to load) and the model manager screen
/// (which shows what's installed, how big it is, and lets the user delete
/// it) go through here so they agree on paths.
///
/// Models are kept under Application Support and flagged as excluded from
/// backup: a 600 MB–3 GB model in Documents would otherwise be uploaded to
/// iCloud on every backup, which is both slow and pointless since it can
/// be re-downloaded.
public struct WhisperModelStore: Sendable {
    public static let repository = "argmaxinc/whisperkit-coreml"

    public let downloadBase: URL

    public init(downloadBase: URL? = nil) {
        if let downloadBase {
            self.downloadBase = downloadBase
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.downloadBase = support.appendingPathComponent("ozen-whisper-models", isDirectory: true)
        }
    }

    /// Mirrors swift-transformers' HubApi layout, which `WhisperKit.download`
    /// uses underneath: `<base>/models/<repo>/<folder>`.
    public var modelsRoot: URL {
        downloadBase
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(Self.repository, isDirectory: true)
    }

    public func folder(for variant: String) -> URL {
        modelsRoot.appendingPathComponent(WhisperModelCatalog.folderName(for: variant), isDirectory: true)
    }

    /// See `ModelFolderInspector` for what "complete" means and why the
    /// bundle directories alone don't prove it.
    public func state(of variant: String) -> ModelFolderState {
        ModelFolderInspector.state(of: folder(for: variant))
    }

    /// The folder for `variant` if a usable model is on disk. A cut-off
    /// download fails this and is simply downloaded again; the hub skips
    /// every file that already arrived, so only the rest is fetched.
    public func installedFolder(for variant: String) -> URL? {
        state(of: variant).isUsable ? folder(for: variant) : nil
    }

    /// Where the tokenizer is cached. It comes from a different hub repo
    /// than the model and is fetched on the first load, so this lives
    /// beside the models: excluded from backup, same base folder.
    public var tokenizerBase: URL { downloadBase }

    /// Whether any Whisper tokenizer has been cached yet. Without one the
    /// first model load needs the internet, which is worth saying plainly
    /// when it fails offline.
    public func hasCachedTokenizer() -> Bool {
        let openai = downloadBase
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("openai", isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: openai.path) else { return false }
        return names.contains { name in
            FileManager.default.fileExists(atPath: openai.appendingPathComponent(name).appendingPathComponent("tokenizer.json").path)
        }
    }

    public func markComplete(variant: String) {
        try? ModelFolderInspector.markComplete(folder(for: variant))
    }

    public func isInstalled(_ variant: String) -> Bool {
        installedFolder(for: variant) != nil
    }

    public func installedVariants() -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: modelsRoot.path) else { return [] }
        return names
            .compactMap(WhisperModelCatalog.variant(fromFolderName:))
            .filter { isInstalled($0) }
            .sorted()
    }

    public func sizeOnDisk(of variant: String) -> Int64 {
        Self.directorySize(folder(for: variant))
    }

    public func totalSizeOnDisk() -> Int64 {
        Self.directorySize(modelsRoot)
    }

    public func delete(variant: String) throws {
        let folder = folder(for: variant)
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        try FileManager.default.removeItem(at: folder)
    }

    /// Downloads (or resumes) a model, reporting 0…1 progress, and returns
    /// the folder to load from.
    public func download(
        variant: String,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        try prepareDownloadBase()
        let folder: URL
        switch WhisperModelCatalog.option(for: variant)?.source ?? .whisperKitHub {
        case .whisperKitHub:
            folder = try await WhisperKit.download(
                variant: variant,
                downloadBase: downloadBase,
                useBackgroundSession: false,
                from: Self.repository,
                progressCallback: { downloadProgress in
                    progress(downloadProgress.fractionCompleted)
                }
            )
        case .ozenRelease(let tag):
            folder = self.folder(for: variant)
            // Compiling at the end takes a moment of its own, so the
            // download's share of the bar stops just short of full.
            _ = try await ReleaseModelDownloader(fetcher: URLSessionReleaseFileFetcher())
                .download(tag: tag, into: folder) { progress($0 * 0.95) }
            try await Self.compilePackages(in: folder)
            progress(1)
        }
        // Only reached when every file arrived: this is the one moment the
        // folder is known to be whole.
        try? ModelFolderInspector.markComplete(folder)
        return folder
    }

    /// Turns each Core ML package a release download left into the
    /// compiled bundle WhisperKit loads, and removes the package. Models
    /// from WhisperKit's hub arrive compiled already; a release built on a
    /// machine without Apple's compiler can't.
    static func compilePackages(in folder: URL) async throws {
        let fileManager = FileManager.default
        let packages = try fileManager.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasSuffix(".mlpackage") }
            .sorted()
        for name in packages {
            let package = folder.appendingPathComponent(name, isDirectory: true)
            let compiled = try await MLModel.compileModel(at: package)
            let target = folder.appendingPathComponent(String(name.dropLast(".mlpackage".count)) + ".mlmodelc", isDirectory: true)
            try? fileManager.removeItem(at: target)
            try fileManager.moveItem(at: compiled, to: target)
            try fileManager.removeItem(at: package)
        }
    }

    private func prepareDownloadBase() throws {
        try FileManager.default.createDirectory(at: downloadBase, withIntermediateDirectories: true)
        var base = downloadBase
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try base.setResourceValues(values)
    }

    private static func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true
            else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }
}
