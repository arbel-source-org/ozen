import Foundation

/// Where to end a line that has run too long without a pause.
///
/// Whisper hears at most 30 seconds at once, so someone telling a story
/// without stopping has their words cut into lines every 28 seconds. Cut at
/// whatever sample the counter reached, the cut often fell inside a word:
/// half of it ended one line, garbled, and the other half began the next.
/// Even fluent speech has short dips between words and at breaths, so the
/// cut goes to the quietest moment of the last couple of seconds instead.
public enum UtteranceCut {
    /// The middle of the quietest `frame`-sample stretch within the
    /// `lookBack` samples before `end`, stepping half a frame at a time.
    /// Returns `end` itself when there's too little audio to choose from.
    /// Of equally quiet stretches the latest wins, so as little as possible
    /// is carried into the next line.
    public static func quietestPoint(in samples: [Float], before end: Int, lookBack: Int, frame: Int) -> Int {
        let end = min(max(end, 0), samples.count)
        let start = max(0, end - max(lookBack, 0))
        guard frame > 1, end - start >= frame else { return end }
        let step = frame / 2
        var best = end
        var bestEnergy = Float.infinity
        var index = start
        while index + frame <= end {
            var energy: Float = 0
            for sample in samples[index..<(index + frame)] {
                energy += sample * sample
            }
            if energy <= bestEnergy {
                bestEnergy = energy
                best = index + step
            }
            index += step
        }
        return best
    }
}
