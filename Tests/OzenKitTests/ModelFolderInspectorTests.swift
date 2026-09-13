import Foundation
import Testing
@testable import OzenKit

@Suite("ModelFolderInspector")
struct ModelFolderInspectorTests {
    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ozen-model-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("openai_whisper-small", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func write(_ relativePath: String, in folder: URL) throws {
        let url = folder.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: url)
    }

    private func writeWholeModel(in folder: URL) throws {
        for bundle in ModelFolderInspector.requiredBundles {
            try write("\(bundle)/coremldata.bin", in: folder)
            try write("\(bundle)/weights/weight.bin", in: folder)
            try write("\(bundle)/model.mil", in: folder)
        }
        try write("config.json", in: folder)
    }

    @Test("no folder is missing")
    func missing() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ozen-nope-\(UUID().uuidString)")
        #expect(ModelFolderInspector.state(of: folder) == .missing)
        #expect(ModelFolderInspector.state(of: folder).isUsable == false)
    }

    @Test("bundle directories that exist but lack their weights are a cut-off download, not a model")
    func weightsMissing() throws {
        let folder = try makeFolder()
        try writeWholeModel(in: folder)
        try FileManager.default.removeItem(at: folder.appendingPathComponent("TextDecoder.mlmodelc/weights/weight.bin"))
        #expect(ModelFolderInspector.state(of: folder) == .partial)
    }

    @Test("a bundle directory holding only its first file is partial")
    func bundleJustStarted() throws {
        let folder = try makeFolder()
        try writeWholeModel(in: folder)
        let decoder = folder.appendingPathComponent("AudioEncoder.mlmodelc")
        try FileManager.default.removeItem(at: decoder)
        try write("AudioEncoder.mlmodelc/analytics/coremldata.bin", in: folder)
        #expect(ModelFolderInspector.state(of: folder) == .partial)
    }

    @Test("a whole model without the marker is usable but unverified; marking it makes it verified")
    func verifyFlow() throws {
        let folder = try makeFolder()
        try writeWholeModel(in: folder)
        #expect(ModelFolderInspector.state(of: folder) == .unverified)
        #expect(ModelFolderInspector.state(of: folder).isUsable)
        try ModelFolderInspector.markComplete(folder)
        #expect(ModelFolderInspector.state(of: folder) == .verified)
    }

    @Test("a marker never vouches for a model whose files were removed afterwards")
    func markerDoesNotLie() throws {
        let folder = try makeFolder()
        try writeWholeModel(in: folder)
        try ModelFolderInspector.markComplete(folder)
        try FileManager.default.removeItem(at: folder.appendingPathComponent("MelSpectrogram.mlmodelc"))
        #expect(ModelFolderInspector.state(of: folder) == .partial)
    }

    @Test("a bundle that ships without a weights directory is still complete")
    func noWeightsDirectory() throws {
        let folder = try makeFolder()
        try writeWholeModel(in: folder)
        try FileManager.default.removeItem(at: folder.appendingPathComponent("MelSpectrogram.mlmodelc/weights"))
        #expect(ModelFolderInspector.state(of: folder) == .unverified)
    }
}
