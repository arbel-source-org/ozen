import Foundation

/// A small, adaptive energy-based voice activity detector. Both engines
/// need to know "is anyone talking right now" — Whisper so it never runs
/// inference on pure silence (wasted battery and, worse, hallucinated
/// text), Apple Speech so it can end a request at a natural pause and
/// start a new utterance. Not a neural VAD; deliberately simple, tuned to
/// be conservative about *missing* speech rather than about false alarms,
/// since a false alarm costs a wasted inference and a miss costs words.
public struct EnergyVoiceDetector: Sendable, Equatable {
    /// Below this RMS (-60 dBFS) nothing counts as speech, whatever the
    /// noise floor says. Guards against a dead-quiet room where the floor
    /// would otherwise drop to ~0 and make breathing count as speech.
    ///
    /// It was -44 dBFS. The session runs in measurement mode, which hands
    /// over the microphone's signal without the automatic gain that makes
    /// calls and voice memos loud, and a phone microphone puts ordinary
    /// conversation a metre or two away somewhere around -45 to -60 dBFS.
    /// In a simulation over 40 LibriSpeech recordings run through this
    /// detector and Whisper's pause logic, speech at -50 dBFS reached
    /// Whisper 20-37% of the time and at -55 dBFS not at all; with -60 dBFS
    /// both reached it 96-97% of the time. Whisper itself doesn't mind the
    /// level: its word error rate was the same at -26 and -56 dBFS.
    public var absoluteThreshold: Float
    /// Speech must exceed the tracked noise floor by this factor.
    public var noiseFloorRatio: Float
    /// How quickly the floor follows a *quieter* signal (per chunk).
    public var floorFallRate: Float
    /// How quickly the floor rises toward a louder non-speech signal
    /// (per chunk). Kept far slower than the fall rate so sustained
    /// speech can't drag the floor up until it counts as noise.
    public var floorRiseRate: Float
    /// The floor never rises above this, so a loud steady hum (a fan next
    /// to the mic) can't switch detection off entirely.
    public var maximumNoiseFloor: Float
    /// How much audio (in samples) the quietest recent moment is taken
    /// from.
    ///
    /// Only quiet chunks feed the floor, so a steady sound louder than the
    /// threshold (a fridge, an air conditioner) would count as speech for
    /// ever, and with the lower threshold that's an ordinary room: Whisper
    /// running on it all evening, in the same simulation 98-100% of the
    /// time. Speech always has gaps within a few seconds, a hum doesn't: so
    /// when even the quietest chunk of the last three seconds is above the
    /// floor, the floor rises toward it, and the hum stops counting while
    /// people talking over it still do.
    ///
    /// Someone talking on without stopping keeps those gaps too: with the
    /// recordings run together 0.1-0.6 s apart for four minutes, in quiet
    /// and in noisy rooms, speech reached Whisper as often with this as
    /// without it (89-94%), and no less in the last minute than the first.
    /// What it does cost is speech barely louder than a hum: 3 dB above a
    /// -55 dBFS hum, a quarter of it got through; 10 dB above, nearly all.
    public var recentWindowSamples: Int
    /// How quickly the floor rises toward that quietest recent level (per
    /// chunk).
    public var recentMinimumRiseRate: Float

    public private(set) var noiseFloor: Float
    public private(set) var lastLevel: Float = 0
    private var recentLevels: [(level: Float, samples: Int)] = []
    private var recentSamples = 0

    public init(
        absoluteThreshold: Float = 0.001,
        noiseFloorRatio: Float = 2.5,
        floorFallRate: Float = 0.3,
        floorRiseRate: Float = 0.02,
        maximumNoiseFloor: Float = 0.02,
        initialNoiseFloor: Float = 0.0004,
        recentWindowSamples: Int = 48_000,
        recentMinimumRiseRate: Float = 0.05
    ) {
        self.absoluteThreshold = absoluteThreshold
        self.noiseFloorRatio = noiseFloorRatio
        self.floorFallRate = floorFallRate
        self.floorRiseRate = floorRiseRate
        self.maximumNoiseFloor = maximumNoiseFloor
        self.noiseFloor = initialNoiseFloor
        self.recentWindowSamples = recentWindowSamples
        self.recentMinimumRiseRate = recentMinimumRiseRate
    }

    public static func == (lhs: EnergyVoiceDetector, rhs: EnergyVoiceDetector) -> Bool {
        lhs.absoluteThreshold == rhs.absoluteThreshold
            && lhs.noiseFloorRatio == rhs.noiseFloorRatio
            && lhs.floorFallRate == rhs.floorFallRate
            && lhs.floorRiseRate == rhs.floorRiseRate
            && lhs.maximumNoiseFloor == rhs.maximumNoiseFloor
            && lhs.recentWindowSamples == rhs.recentWindowSamples
            && lhs.recentMinimumRiseRate == rhs.recentMinimumRiseRate
            && lhs.noiseFloor == rhs.noiseFloor
            && lhs.lastLevel == rhs.lastLevel
            && lhs.recentSamples == rhs.recentSamples
            && lhs.recentLevels.elementsEqual(rhs.recentLevels) { $0.level == $1.level && $0.samples == $1.samples }
    }

    public var threshold: Float {
        max(absoluteThreshold, noiseFloor * noiseFloorRatio)
    }

    /// Classifies one chunk and updates the noise floor. Chunks that are
    /// *not* speech feed the floor, which is what keeps a long monologue
    /// from being reclassified as background noise; a sound with no quiet
    /// moment in the last few seconds lifts it too (see
    /// `recentWindowSamples`).
    @discardableResult
    public mutating func isSpeech(_ samples: [Float]) -> Bool {
        let level = Self.rms(samples)
        lastLevel = level
        followQuietestRecentLevel(level, samples: samples.count)
        let speech = level > threshold
        if !speech {
            if level < noiseFloor {
                noiseFloor += (level - noiseFloor) * floorFallRate
            } else {
                noiseFloor += (level - noiseFloor) * floorRiseRate
            }
            noiseFloor = min(noiseFloor, maximumNoiseFloor)
        }
        return speech
    }

    private mutating func followQuietestRecentLevel(_ level: Float, samples: Int) {
        guard recentWindowSamples > 0, samples > 0 else { return }
        recentLevels.append((level, samples))
        recentSamples += samples
        while let oldest = recentLevels.first, recentSamples - oldest.samples >= recentWindowSamples {
            recentLevels.removeFirst()
            recentSamples -= oldest.samples
        }
        // Only once the window holds a full few seconds: at the start of
        // listening the first chunk alone is the "quietest".
        guard recentSamples >= recentWindowSamples,
              let quietest = recentLevels.map(\.level).min(),
              quietest > noiseFloor
        else { return }
        noiseFloor = min(noiseFloor + (quietest - noiseFloor) * recentMinimumRiseRate, maximumNoiseFloor)
    }

    public static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples {
            sum += sample * sample
        }
        return (sum / Float(samples.count)).squareRoot()
    }

    /// Maps an RMS level to 0...1 for a meter, on a decibel scale from
    /// -70 dBFS (silent) to 0 dBFS (clipping), which is how loudness is
    /// actually perceived. The bottom was -50 dBFS, where the meter sat
    /// still through conversation arriving at -55 dBFS and looked like a
    /// dead microphone.
    public static func meterLevel(forRMS rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let decibels = 20 * log10(rms)
        return min(max((decibels + 70) / 70, 0), 1)
    }
}
