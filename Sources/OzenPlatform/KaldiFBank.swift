import Foundation
import Accelerate

/// An 80-bin, Kaldi-compatible log mel filterbank: the front end the CAM++
/// speaker embedder was trained on (`CAMPlusPlusSpeakerEmbedder`), computed
/// here in Swift because CoreML takes the filterbank as input, not raw
/// audio. It has to match the reference feature extractor
/// (`kaldi_native_fbank`, the library WeSpeaker's own training and eval
/// pipeline uses) closely enough that a print made here lines up with one
/// made there — `KaldiFBankTests` checks it against frames computed by that
/// library on real speech, not just against a hand derivation of the math.
///
/// 25ms frames every 10ms, a Povey window (like Hamming but tapered to zero
/// at both edges — `pow(0.5 - 0.5*cos(...), 0.85)`), DC removal then 0.97
/// pre-emphasis before windowing, an 80-band triangular filterbank in
/// Kaldi's mel scale (`1127 * ln(1 + hz/700)`, not the HTK/librosa
/// constant), a natural-log floor, then mean subtraction over time per
/// band — the same per-utterance normalization `MFCCSpeakerEmbedder` skips
/// the first coefficient for: it makes the print roughly loudness-invariant
/// without needing a fixed reference level.
public struct KaldiFBank {
    public static let melBinCount = 80

    private let frameSize = 400   // 25ms @ 16kHz
    private let hopSize = 160     // 10ms @ 16kHz
    private let fftSize = 512
    private let preemphasisCoefficient: Float = 0.97
    private let poveyExponent = 0.85
    private let lowFreqHz = 20.0

    public init() {}

    /// One row per 25ms frame, `Self.melBinCount` log mel energies each,
    /// already mean-subtracted over time. Nil if `samples` is too short to
    /// extract even one frame.
    public func frames(samples: [Float], sampleRate: Double) -> [[Float]]? {
        guard samples.count >= frameSize else { return nil }

        let filterbank = melFilterbank(sampleRate: sampleRate)
        let window = poveyWindow()
        guard let fftSetup = vDSP_create_fftsetup(vDSP_Length(log2(Double(fftSize))), FFTRadix(kFFTRadix2)) else {
            return nil
        }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        var frames: [[Float]] = []
        var offset = 0
        while offset + frameSize <= samples.count {
            let frame = Array(samples[offset..<(offset + frameSize)])
            frames.append(logMelEnergies(for: frame, window: window, filterbank: filterbank, fftSetup: fftSetup))
            offset += hopSize
        }
        guard !frames.isEmpty else { return nil }
        return meanNormalized(frames)
    }

    private func logMelEnergies(for rawFrame: [Float], window: [Float], filterbank: [[Float]], fftSetup: FFTSetup) -> [Float] {
        var frame = rawFrame

        // Remove DC offset: subtract the frame's own mean.
        var mean: Float = 0
        vDSP_meanv(frame, 1, &mean, vDSP_Length(frameSize))
        var negativeMean = -mean
        vDSP_vsadd(frame, 1, &negativeMean, &frame, 1, vDSP_Length(frameSize))

        // Pre-emphasis, high index to low so each sample still reads its
        // *original* predecessor: frame[i] -= 0.97 * frame[i-1], then
        // frame[0] -= 0.97 * frame[0] (i.e. frame[0] *= 0.03).
        for i in stride(from: frameSize - 1, through: 1, by: -1) {
            frame[i] -= preemphasisCoefficient * frame[i - 1]
        }
        frame[0] -= preemphasisCoefficient * frame[0]

        vDSP_vmul(frame, 1, window, 1, &frame, 1, vDSP_Length(frameSize))

        let padded = frame + [Float](repeating: 0, count: fftSize - frameSize)
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

                // Accelerate's packed real-FFT format folds the DC and
                // Nyquist bins together into slot 0 (realp[0] is DC,
                // imagp[0] is actually the real-valued Nyquist bin, not an
                // imaginary part). Kaldi's power spectrum keeps them apart
                // — bin 0 is DC energy alone — so `vDSP_zvmags` over the
                // whole buffer would silently mix a stray Nyquist term into
                // the lowest mel band. The Nyquist value itself is never
                // read: Kaldi's filters only cover bins 0..<fftSize/2.
                magnitudes[0] = realPtr[0] * realPtr[0]
                for k in 1..<(fftSize / 2) {
                    magnitudes[k] = realPtr[k] * realPtr[k] + imagPtr[k] * imagPtr[k]
                }
            }
        }

        var melEnergies = [Float](repeating: 0, count: filterbank.count)
        for bin in filterbank.indices {
            var sum: Float = 0
            for k in magnitudes.indices { sum += magnitudes[k] * filterbank[bin][k] }
            // Float.ulpOfOne == FLT_EPSILON, the same floor Kaldi uses
            // before taking the natural log.
            melEnergies[bin] = logf(max(sum, Float.ulpOfOne))
        }
        return melEnergies
    }

    /// Subtracts each band's mean over time from every frame: a per-
    /// utterance normalization, not a global one, so it works the same on
    /// a short window as on a long enrollment recording.
    private func meanNormalized(_ frames: [[Float]]) -> [[Float]] {
        let binCount = frames[0].count
        var means = [Float](repeating: 0, count: binCount)
        for frame in frames {
            for i in 0..<binCount { means[i] += frame[i] }
        }
        for i in 0..<binCount { means[i] /= Float(frames.count) }
        return frames.map { frame in
            var normalized = frame
            for i in 0..<binCount { normalized[i] -= means[i] }
            return normalized
        }
    }

    /// Like Hamming but tapered to zero at both edges, which Kaldi uses by
    /// default in place of Hann/Hamming.
    private func poveyWindow() -> [Float] {
        (0..<frameSize).map { i in
            let x = 0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(frameSize - 1))
            return Float(pow(x, poveyExponent))
        }
    }

    /// Kaldi's triangular mel filterbank: bin edges spaced evenly in
    /// Kaldi's own mel scale (`1127 * ln(1 + hz/700)`), each filter's
    /// weight at an FFT bin taken from *that bin's center frequency*
    /// (`fftBinWidth * i`), not the bin's index directly.
    private func melFilterbank(sampleRate: Double) -> [[Float]] {
        let numFFTBins = fftSize / 2
        let nyquist = sampleRate / 2
        let fftBinWidth = sampleRate / Double(fftSize)
        func melScale(_ hz: Double) -> Double { 1127.0 * log(1.0 + hz / 700.0) }

        let melLow = melScale(lowFreqHz)
        let melHigh = melScale(nyquist)
        let melDelta = (melHigh - melLow) / Double(Self.melBinCount + 1)

        var filters = [[Float]](repeating: [Float](repeating: 0, count: numFFTBins), count: Self.melBinCount)
        for bin in 0..<Self.melBinCount {
            let leftMel = melLow + Double(bin) * melDelta
            let centerMel = melLow + Double(bin + 1) * melDelta
            let rightMel = melLow + Double(bin + 2) * melDelta
            for i in 0..<numFFTBins {
                let mel = melScale(fftBinWidth * Double(i))
                guard mel > leftMel, mel < rightMel else { continue }
                let weight = mel <= centerMel
                    ? (mel - leftMel) / (centerMel - leftMel)
                    : (rightMel - mel) / (rightMel - centerMel)
                filters[bin][i] = Float(weight)
            }
        }
        return filters
    }
}
