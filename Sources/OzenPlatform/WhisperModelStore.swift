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

    /// The folder for `variant` if a complete model is on disk. "Complete"
    /// means the three compiled CoreML bundles the loader looks for exist;
    /// a half-finished download has a folder but fails this check and is
    /// simply re-downloaded (HubApi resumes what's already there).
    public func installedFolder(for variant: String) -> URL? {
        let folder = folder(for: variant)
        let required = ["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc"]
        let complete = required.allSatisfy { name in
            FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path)
        }
        return complete ? folder : nil
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
        let folder = try await WhisperKit.download(
            variant: variant,
            downloadBase: downloadBase,
            useBackgroundSession: false,
            from: Self.repository,
            progressCallback: { downloadProgress in
                progress(downloadProgress.fractionCompleted)
            }
        )
        return folder
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
