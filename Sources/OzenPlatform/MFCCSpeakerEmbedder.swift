import Foundation
import Accelerate
import OzenKit

/// v1 embedder: classic MFCC features (via Accelerate/vDSP), averaged over
/// the utterance into one vector. This is **not** a deep speaker-embedding
/// model — that's the named v2 upgrade path — but it requires no training
/// pipeline or model-conversion step to ship a working first version. Its
/// actual clustering quality on real family voices is explicitly an open
/// question for the manual hardware test pass, not assumed here.
///
/// The print leaves out the first coefficient, which is only how loud the
/// sound was. It used to be included and it outweighed everything else:
/// measured over 26 speakers of the LibriSpeech test set, any two voices
/// scored about 0.95 alike, so at the 0.75 threshold a table of four people
/// became one speaker, a saved voice's name went on everybody's lines, and
/// the same person 20 dB quieter (further from the phone) scored as a
/// stranger. Without it the print doesn't change with loudness at all, and
/// in the same simulated four-person tables 70-80% of lines went to a label
/// of their own speaker's.
public struct MFCCSpeakerEmbedder: SpeakerEmbedding {
    private let frameSize = 400   // 25ms @ 16kHz
    private let hopSize = 160     // 10ms @ 16kHz
    private let fftSize = 512
    private let melBinCount = 26
    /// Coefficients 1 through 12 of the cepstrum.
    static let coefficientCount = SpeakerProfile.voicePrintLength
    public var embeddingLength: Int? { Self.coefficientCount }

    public init() {}

    // See this file's own doc comment: MFCC cosine scores sit on a
    // completely different scale than CAM++'s, so a silent fallback to
    // this embedder must not inherit AppSettings' CAM++-tuned default.
    public var recommendedSimilarityThreshold: Float { 0.75 }

    public func embed(samples: [Float], sampleRate: Double) -> [Float]? {
        guard samples.count >= frameSize else { return nil }

        let filterbank = melFilterbank(sampleRate: sampleRate)
        guard let fftSetup = vDSP_create_fftsetup(vDSP_Length(log2(Double(fftSize))), FFTRadix(kFFTRadix2)) else {
            return nil
        }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        var accumulated = [Float](repeating: 0, count: Self.coefficientCount)
        var frameCount = 0
        var offset = 0
        while offset + frameSize <= samples.count {
            let frame = Array(samples[offset..<(offset + frameSize)])
            if let coefficients = mfcc(for: frame, filterbank: filterbank, fftSetup: fftSetup) {
                for i in 0..<Self.coefficientCount { accumulated[i] += coefficients[i] }
                frameCount += 1
            }
            offset += hopSize
        }

        guard frameCount > 0 else { return nil }
        return accumulated.map { $0 / Float(frameCount) }
    }

    private func mfcc(for frame: [Float], filterbank: [[Float]], fftSetup: FFTSetup) -> [Float]? {
        var window = [Float](repeating: 0, count: frameSize)
        vDSP_hann_window(&window, vDSP_Length(frameSize), Int32(vDSP_HANN_NORM))

        var windowed = [Float](repeating: 0, count: frameSize)
        vDSP_vmul(frame, 1, window, 1, &windowed, 1, vDSP_Length(frameSize))

        let padded = windowed + [Float](repeating: 0, count: fftSize - frameSize)
        var realp = [Float](repeating: 0, count: fftSize / 2)
        var imagp = [Float](repeating: 0, count: fftSize / 2)
        var magnitudes = [Float](repeating: 0, count: fftSize / 2)

        realp.withUnsafeMutableBufferPointer { realPtr in
            imagp.withUnsafeMutableBufferPointer { imagPtr in
                var splitComplex = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                padded.withUnsafeBufferPointer { paddedPtr in
                    paddedPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) { complexPtr in
                        vDSP_ctoz(complexPtr, 2, &splitComplex, 1, vDSP_Length(fftSize / 2))
                    }
                }
                vDSP_fft_zrip(fftSetup, &splitComplex, 1, vDSP_Length(log2(Double(fftSize))), FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&splitComplex, 1, &magnitudes, 1, vDSP_Length(fftSize / 2))
            }
        }

        var melEnergies = [Float](repeating: 0, count: melBinCount)
        for band in 0..<melBinCount {
            var sum: Float = 0
            for bin in magnitudes.indices {
                sum += magnitudes[bin] * filterbank[band][bin]
            }
            melEnergies[band] = logf(max(sum, 1e-10))
        }

        // DCT-II, coefficients 1 through `coefficientCount`. Coefficient 0
        // is the sum of the log energies: a louder sound adds the same
        // amount to every band, which lands entirely in it.
        var coefficients = [Float](repeating: 0, count: Self.coefficientCount)
        for k in 1...Self.coefficientCount {
            var sum: Float = 0
            for n in 0..<melBinCount {
                sum += melEnergies[n] * cosf(Float.pi / Float(melBinCount) * (Float(n) + 0.5) * Float(k))
            }
            coefficients[k - 1] = sum
        }
        return coefficients
    }

    private func melFilterbank(sampleRate: Double) -> [[Float]] {
        let binCount = fftSize / 2
        func hzToMel(_ hz: Double) -> Double { 2595 * log10(1 + hz / 700) }
        func melToHz(_ mel: Double) -> Double { 700 * (pow(10, mel / 2595) - 1) }

        let lowMel = hzToMel(0)
        let highMel = hzToMel(sampleRate / 2)
        let melPoints = (0...(melBinCount + 1)).map { lowMel + (highMel - lowMel) * Double($0) / Double(melBinCount + 1) }
        let hzPoints = melPoints.map(melToHz)
        let binIndices = hzPoints.map { Int(($0 / (sampleRate / 2)) * Double(binCount)) }

        var filters = [[Float]](repeating: [Float](repeating: 0, count: binCount), count: melBinCount)
        for m in 1...melBinCount {
            let left = binIndices[m - 1], center = binIndices[m], right = binIndices[m + 1]
            if center > left {
                for k in left..<min(center, binCount) {
                    filters[m - 1][k] = Float(k - left) / Float(max(center - left, 1))
                }
            }
            if right > center {
                for k in center..<min(right, binCount) {
                    filters[m - 1][k] = Float(right - k) / Float(max(right - center, 1))
                }
            }
        }
        return filters
    }
}
