import Foundation
import Testing
@testable import OzenKit

@Suite("ModelLoadMarker")
struct ModelLoadMarkerTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("marker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("a model never loaded is set up the long way")
    func neverLoaded() throws {
        #expect(!ModelLoadMarker.hasLoadedBefore(try folder(), system: "Version 26.0 (Build 23A341)"))
    }

    @Test("loaded on this iOS: quick; after an iOS update: set up the long way again")
    func iOSUpdate() throws {
        let model = try folder()
        ModelLoadMarker.markLoaded(model, system: "Version 26.0 (Build 23A341)")
        #expect(ModelLoadMarker.hasLoadedBefore(model, system: "Version 26.0 (Build 23A341)"))
        #expect(!ModelLoadMarker.hasLoadedBefore(model, system: "Version 26.1 (Build 23B85)"))

        ModelLoadMarker.markLoaded(model, system: "Version 26.1 (Build 23B85)")
        #expect(ModelLoadMarker.hasLoadedBefore(model, system: "Version 26.1 (Build 23B85)"))
    }

    @Test("a marker from before the iOS version was kept still counts")
    func olderEmptyMarker() throws {
        let model = try folder()
        FileManager.default.createFile(atPath: model.appendingPathComponent(ModelLoadMarker.fileName).path, contents: nil)
        #expect(ModelLoadMarker.fileName == ".ozen-loaded-once")
        #expect(ModelLoadMarker.hasLoadedBefore(model, system: "Version 26.1 (Build 23B85)"))
    }
}
