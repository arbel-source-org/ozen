import AVFoundation

public enum AudioFileSamples {
    public static let maximumSeconds = 600.0

    public static func load(_ url: URL, sampleRate: Double = 16_000) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url),
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: file.processingFormat, to: target)
        else { return nil }
        let sourceRate = file.processingFormat.sampleRate
        let sourceFrames = min(file.length, AVAudioFramePosition(maximumSeconds * sourceRate))
        guard sourceFrames > 0,
              let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(sourceFrames)),
              (try? file.read(into: source, frameCount: AVAudioFrameCount(sourceFrames))) != nil
        else { return nil }
        let capacity = AVAudioFrameCount(Double(source.frameLength) * sampleRate / sourceRate) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var handedOver = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if handedOver {
                inputStatus.pointee = .endOfStream
                return nil
            }
            handedOver = true
            inputStatus.pointee = .haveData
            return source
        }
        guard status != .error, error == nil, let channel = output.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
    }
}
