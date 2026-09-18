import Foundation

public enum SpeechGain {
    public static let targetPeak: Float = 0.5
    public static let maximumGain: Float = 100

    public static func gain(for samples: [Float]) -> Float {
        var magnitudes: [Float] = []
        magnitudes.reserveCapacity(samples.count / 4 + 1)
        for index in stride(from: 0, to: samples.count, by: 4) where samples[index].isFinite {
            magnitudes.append(abs(samples[index]))
        }
        guard !magnitudes.isEmpty else { return 1 }
        magnitudes.sort()
        let loud = magnitudes[min(magnitudes.count - 1, Int(Float(magnitudes.count) * 0.999))]
        guard loud > 0 else { return 1 }
        return min(max(targetPeak / loud, 1), maximumGain)
    }

    public static func normalized(_ samples: [Float]) -> [Float] {
        let gain = gain(for: samples)
        guard gain > 1 else { return samples }
        return samples.map { min(max($0 * gain, -1), 1) }
    }
}
