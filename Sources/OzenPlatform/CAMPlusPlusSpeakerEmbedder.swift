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
    private let modelURL: URL
    private let fbank = KaldiFBank()
    /// The model is loaded the first time a window is embedded, not when the
    /// app starts. Loading it in `init` put it on the main thread before the
    /// first screen was drawn, and CoreML's first load of a model on a phone
    /// (or after iOS has cleared its cache) can take tens of seconds: a white
    /// screen for that long, and the launch watchdog ending the app when it
    /// ran over. `embed` is only ever called off the main thread.
    private let lock = NSLock()
    private var loadedModel: MLModel?
    private var loadFailed = false

    /// Nil if the bundled model can't be found, a corrupt install rather than
    /// something to crash the app launching over. Callers fall back to
    /// `MFCCSpeakerEmbedder`. Only the file's presence is checked here; a
    /// model that is there but won't load gives no voice prints, and so no
    /// speaker labels, until the next launch.
    ///
    /// Looks for `.mlmodelc`, not the `.mlpackage` the source tree and
    /// `Package.swift` name: Xcode's own SPM integration compiles a
    /// `resources: [.copy(...)]`-declared `.mlpackage` to `.mlmodelc` as
    /// part of the build (CoreML gets this special handling regardless of
    /// `.copy` vs `.process`), so that's what actually ends up in
    /// `Bundle.module` — confirmed by CI, not assumed.
    public init?() {
        guard let modelURL = Bundle.module.url(forResource: "CAMPlusPlus", withExtension: "mlmodelc") else {
            return nil
        }
        self.modelURL = modelURL
    }

    /// Loads the model on the CPU. This model is small (7.3M parameters) and
    /// a window is embedded every second or so, which the CPU does in a few
    /// milliseconds. The default lets CoreML also compile it for the Neural
    /// Engine, which is the slow, cached, and sometimes-lost part of a first
    /// load, and gives nothing here.
    private func model() -> MLModel? {
        lock.lock()
        defer { lock.unlock() }
        if let loadedModel { return loadedModel }
        guard !loadFailed else { return nil }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuOnly
        do {
            let model = try MLModel(contentsOf: modelURL, configuration: configuration)
            loadedModel = model
            return model
        } catch {
            loadFailed = true
            return nil
        }
    }

    public func embed(samples: [Float], sampleRate: Double) -> [Float]? {
        guard let model = model(),
              let frames = fbank.frames(samples: samples, sampleRate: sampleRate),
              let input = try? featureArray(from: fixedLength(frames)),
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

    /// The bundled model's declared CoreML input signature accepts any
    /// frame count from 1 to 300 (`feats`' `RangeDim`), but that's not
    /// actually honored end to end: partway through its frequency-context
    /// module — right after the two stride-2 convs that fold the 80 mel
    /// bins down to 10 — one `reshape` hardcodes its target shape to a
    /// literal `[1, 320, 148]` rather than deriving the time dimension
    /// from the tensor it's reshaping. That's WeSpeaker's own ONNX export
    /// baked in (traced at exactly 148 frames = 1.48s), not something the
    /// CoreML conversion introduced — confirmed by dumping the model's MIL
    /// program with `coremltools.utils.load_spec`, which shows every
    /// other op's time dimension as symbolic ("unknown") except this one
    /// `const`. Feeding anything but exactly 148 frames makes
    /// `model.prediction(from:)` throw a generic, unhelpful "Unable to
    /// compute the prediction ... invalid input data or broken/unsupported
    /// model" error, which the `try?` chain above turns into a plain nil.
    ///
    /// So: pad a short clip with trailing all-zero frames (frames are
    /// already mean-subtracted per `KaldiFBank`, so a zero row reads as
    /// near-silence rather than a loud transient) and truncate a long one
    /// to its first 148 — never resample or stretch, which would change
    /// what the model actually hears. This matches `CaptionPipeline`'s own
    /// ~148-frame (1.5s) embedding window; it's the test fixtures here
    /// (1.8s clips) that run long.
    private static let modelFrameCount = 148

    private func fixedLength(_ frames: [[Float]]) -> [[Float]] {
        if frames.count == Self.modelFrameCount { return frames }
        if frames.count > Self.modelFrameCount { return Array(frames.prefix(Self.modelFrameCount)) }
        let silence = [Float](repeating: 0, count: KaldiFBank.melBinCount)
        return frames + [[Float]](repeating: silence, count: Self.modelFrameCount - frames.count)
    }

    /// `feats`, shaped [1, frame count, 80] as the model expects.
    private func featureArray(from frames: [[Float]]) throws -> MLMultiArray {
        let array = try MLMultiArray(
            shape: [1, NSNumber(value: frames.count), NSNumber(value: KaldiFBank.melBinCount)],
            dataType: .float32
        )
        for (t, frame) in frames.enumerated() {
            for (bin, value) in frame.enumerated() {
                array[[NSNumber(value: 0), NSNumber(value: t), NSNumber(value: bin)]] = NSNumber(value: value)
            }
        }
        return array
    }
}

/// The one input CoreML asks for: `MLDictionaryFeatureProvider` also
/// works, but boxing a single named tensor by hand skips a dictionary and
/// a round trip through `MLFeatureValue`'s type inference.
private final class SingleFeatureProvider: MLFeatureProvider {
    let name: String
    let value: MLFeatureValue

    init(name: String, value: MLFeatureValue) {
        self.name = name
        self.value = value
    }

    var featureNames: Set<String> { [name] }

    func featureValue(for featureName: String) -> MLFeatureValue? {
        featureName == name ? value : nil
    }
}
