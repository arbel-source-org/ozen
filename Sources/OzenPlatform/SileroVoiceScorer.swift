import CoreML
import Foundation
import OzenKit

public final class SileroVoiceScorer: @unchecked Sendable {
    private static let stateSize = 128
    private let model: MLModel
    private var hidden = [Float](repeating: 0, count: SileroVoiceScorer.stateSize)
    private var cell = [Float](repeating: 0, count: SileroVoiceScorer.stateSize)

    public init?() {
        guard let url = Bundle.module.url(forResource: "SileroVAD", withExtension: "mlmodelc") else { return nil }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuOnly
        guard let model = try? MLModel(contentsOf: url, configuration: configuration) else { return nil }
        self.model = model
    }

    public func score(_ input: [Float]) -> Float? {
        guard input.count == VoiceEvidence.contextSamples + VoiceEvidence.chunkSamples,
              let audio = Self.array(input),
              let hiddenIn = Self.array(hidden),
              let cellIn = Self.array(cell),
              let features = try? MLDictionaryFeatureProvider(dictionary: [
                  "audio_input": audio, "hidden_state": hiddenIn, "cell_state": cellIn,
              ]),
              let output = try? model.prediction(from: features),
              let probability = Self.output(output, named: "vad_output"),
              let newHidden = Self.output(output, named: "new_hidden_state"),
              let newCell = Self.output(output, named: "new_cell_state"),
              newHidden.count == Self.stateSize, newCell.count == Self.stateSize,
              let value = probability.first, value.isFinite
        else { return nil }
        hidden = newHidden
        cell = newCell
        return value
    }

    private static func array(_ values: [Float]) -> MLMultiArray? {
        guard let array = try? MLMultiArray(shape: [1, NSNumber(value: values.count)], dataType: .float32) else { return nil }
        let pointer = array.dataPointer.assumingMemoryBound(to: Float.self)
        for (i, value) in values.enumerated() { pointer[i] = value }
        return array
    }

    private static func output(_ provider: MLFeatureProvider, named name: String) -> [Float]? {
        guard let key = provider.featureNames.first(where: { $0 == name }) ?? provider.featureNames.first(where: { $0.contains(name) }),
              let array = provider.featureValue(for: key)?.multiArrayValue,
              array.dataType == .float32
        else { return nil }
        let pointer = array.dataPointer.assumingMemoryBound(to: Float.self)
        return Array(UnsafeBufferPointer(start: pointer, count: array.count))
    }
}
