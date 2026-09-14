import Foundation
import AVFoundation

/// Ground truth from the Python research pipeline (see `KaldiFBank` and
/// `CAMPlusPlusSpeakerEmbedder`'s doc comments): the same fbank frames and
/// CAM++ embeddings WeSpeaker's own `kaldi_native_fbank` + ONNX runtime
/// compute on three real, bundled speech clips.
struct SpeakerFixture: Codable {
    let sampleRate: Double
    let clips: [String: Clip]

    struct Clip: Codable {
        let wavFile: String
        let frameCount: Int
        let firstFrames: [[Float]]
        let embedding: [Float]
    }
}

enum SpeakerFixtureError: Error {
    case resourceNotFound(String)
}

/// These tests are compiled straight into the `OzenTests` Xcode bundle
/// (see `project.yml`) rather than run as the standalone SPM
/// `OzenPlatformTests` target, so `Bundle.module` — the SPM-synthesized
/// accessor — doesn't exist for them; this locates the fixture files by
/// searching the test bundle's own resources instead, wherever XcodeGen
/// happens to have placed them.
private final class FixtureBundleLocator {}

enum SpeakerFixtureLoading {
    private static func resourceURL(named filename: String) throws -> URL {
        let bundle = Bundle(for: FixtureBundleLocator.self)
        if let direct = bundle.url(forResource: filename, withExtension: nil) {
            return direct
        }
        if let resourceRoot = bundle.resourceURL,
           let enumerator = FileManager.default.enumerator(at: resourceRoot, includingPropertiesForKeys: nil) {
            for case let url as URL in enumerator where url.lastPathComponent == filename {
                return url
            }
        }
        throw SpeakerFixtureError.resourceNotFound(filename)
    }

    static func load() throws -> SpeakerFixture {
        let data = try Data(contentsOf: resourceURL(named: "speaker_fixture.json"))
        return try JSONDecoder().decode(SpeakerFixture.self, from: data)
    }

    /// 16kHz mono samples as `KaldiFBank`/`CAMPlusPlusSpeakerEmbedder`
    /// expect, converted through `AVAudioFile` rather than a hand-rolled
    /// WAV parser.
    static func readSamples(named filename: String) throws -> [Float] {
        let file = try AVAudioFile(forReading: try resourceURL(named: filename), commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw SpeakerFixtureError.resourceNotFound(filename)
        }
        try file.read(into: buffer)
        guard let channelData = buffer.floatChannelData else {
            throw SpeakerFixtureError.resourceNotFound(filename)
        }
        return Array(UnsafeBufferPointer(start: channelData[0], count: Int(buffer.frameLength)))
    }
}
