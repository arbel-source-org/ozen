import Foundation
import AVFoundation

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

    static func data(named filename: String) throws -> Data {
        try Data(contentsOf: resourceURL(named: filename))
    }

    static func load() throws -> SpeakerFixture {
        let data = try data(named: "speaker_fixture.json")
        return try JSONDecoder().decode(SpeakerFixture.self, from: data)
    }

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
