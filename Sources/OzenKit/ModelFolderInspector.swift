import Foundation

/// How much of a Whisper model is on disk.
public enum ModelFolderState: Sendable, Equatable {
    /// No folder at all.
    case missing
    /// Some files, but not a loadable model: a download that was cut off.
    case partial
    /// Every bundle looks present but no download ever confirmed it. Only
    /// folders from builds before the completion marker end up here.
    case unverified
    /// A download finished and wrote the marker.
    case verified

    public var isUsable: Bool { self == .unverified || self == .verified }
}

/// Decides whether a model folder is really a whole model.
///
/// The model hub downloads a model file by file, and each compiled CoreML
/// bundle is a directory that appears as soon as its *first* file lands.
/// So "the three bundle directories exist" is also true of a download
/// that died halfway, and a folder like that fails to load on every
/// launch. A marker written only after the download call returns is the
/// reliable signal. Folders without one are judged by the files CoreML
/// can't load without, and the engine re-checks them against the hub
/// before trusting them.
public enum ModelFolderInspector {
    public static let markerName = ".ozen-download-complete"
    public static let requiredBundles = ["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc"]

    public static func state(of folder: URL, fileManager: FileManager = .default) -> ModelFolderState {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .missing
        }
        guard bundlesLookComplete(in: folder, fileManager: fileManager) else {
            return .partial
        }
        return fileManager.fileExists(atPath: folder.appendingPathComponent(markerName).path) ? .verified : .unverified
    }

    /// Records that a download of `folder` completed. Written atomically so
    /// a crash mid-write can't leave a marker that exists but lies.
    public static func markComplete(_ folder: URL, at date: Date = Date()) throws {
        let stamp = ISO8601DateFormatter().string(from: date)
        try Data("completed \(stamp)\n".utf8).write(to: folder.appendingPathComponent(markerName), options: .atomic)
    }

    /// Every compiled bundle has its `coremldata.bin`, and any bundle that
    /// has a weights directory has its weights file in it. A bundle's
    /// weights are its largest file and the last to arrive, so this is the
    /// part an interrupted download is most likely to be missing.
    static func bundlesLookComplete(in folder: URL, fileManager: FileManager) -> Bool {
        requiredBundles.allSatisfy { name in
            let bundle = folder.appendingPathComponent(name, isDirectory: true)
            guard fileManager.fileExists(atPath: bundle.appendingPathComponent("coremldata.bin").path) else {
                return false
            }
            let weights = bundle.appendingPathComponent("weights", isDirectory: true)
            var weightsIsDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: weights.path, isDirectory: &weightsIsDirectory), weightsIsDirectory.boolValue {
                return fileManager.fileExists(atPath: weights.appendingPathComponent("weight.bin").path)
            }
            return true
        }
    }
}
