import Foundation
import CoreML
import OzenKit

/// v2 embedder: WeSpeaker CAM++, a small (7.3M-parameter) neural speaker
/// embedding model, run entirely on-device via CoreML. Replaces
/// `MFCCSpeakerEmbedder` as the one `LiveCaptionViewModel` wires up (see its
/// `init(settingsStore:)`), which is kept in place, unused, as the fallback
/// this type's failable `init?` exists for.
///
/// Measured on the same LibriSpeech clustering test `MFCCSpeakerEmbedder`'s
/// doc comment cites: CAM++'s equal-error rate is 2.6%, against MFCC's
/// 20.6%. Each embedder has a very different usable similarity threshold —
/// scores between two clips just sit on a different scale — and at its own
/// threshold CAM++ clusters four-person tables correctly 96.8% of the time
/// (threshold 0.45) against MFCC's 45.8% (0.75); `AppSettings`'
/// `speakerSimilarityThreshold` default moved to 0.45 for it.
///
/// The model takes an 80-bin Kaldi mel filterbank, not raw audio —
/// `KaldiFBank` reproduces the exact front end WeSpeaker was trained on.
public final class CAMPlusPlusSpeakerEmbedder: SpeakerEmbedding, @unchecked Sendable {
    private let model: MLModel
    private let fbank = KaldiFBank()

    /// Nil if the bundled model can't be found, compiled or loaded — a
    /// corrupt install, not something to crash the app launching over.
    /// Callers fall back to `MFCCSpeakerEmbedder`.
    public init?() {
        guard let packageURL = Bundle.module.url(forResource: "CAMPlusPlus", withExtension: "mlpackage") else {
            return nil
        }
        do {
            let compiledURL = try MLModel.compileModel(at: packageURL)
            model = try MLModel(contentsOf: compiledURL)
        } catch {
            return nil
        }
    }

    public func embed(samples: [Float], sampleRate: Double) -> [Float]? {
        guard let frames = fbank.frames(samples: samples, sampleRate: sampleRate),
              let input = try? featureArray(from: frames),
              let output = try? model.prediction(from: SingleFeatureProvider(name: "feats", value: MLFeatureValue(multiArray: input))),
              let embedding = output.featureValue(for: "embs")?.multiArrayValue
        else { return nil }

        var result = [Float](repeating: 0, count: embedding.count)
        for i in 0..<embedding.count {
            result[i] = embedding[i].floatValue
        }
        guard result.allSatisfy(\.isFinite) else { return nil }
        return result
    }

    /// `feats`, shaped [1, frame count, 80] as the model expects.
    private func featureArray(from frames: [[Float]]) throws -> MLMultiArray {
        let array = try MLMultiArray(
            shape: [1, NSNumber(value: frames.count), NSNumber(value: KaldiFBank.melBinCount)],
            dataType: .float32
        )
        for (t, frame) in frames.enumerated() {
            for (bin, value) in frame.enumerated() {
                array[[0, t, bin] as [NSNumber]] = NSNumber(value: value)
            }
        }
        return array
    }
}

/// The one input CoreML asks for: `MLDictionaryFeatureProvider` also
/// works, but boxing a single named tensor by hand skips a dictionary and
/// a round trip through `MLFeatureValue`'s type inference.
private struct SingleFeatureProvider: MLFeatureProvider {
    let name: String
    let value: MLFeatureValue

    var featureNames: Set<String> { [name] }

    func featureValue(for featureName: String) -> MLFeatureValue? {
        featureName == name ? value : nil
    }
}
