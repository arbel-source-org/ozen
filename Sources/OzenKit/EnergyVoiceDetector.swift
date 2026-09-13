import Foundation

/// A small, adaptive energy-based voice activity detector. Both engines
/// need to know "is anyone talking right now" — Whisper so it never runs
/// inference on pure silence (wasted battery and, worse, hallucinated
/// text), Apple Speech so it can end a request at a natural pause and
/// start a new utterance. Not a neural VAD; deliberately simple, tuned to
/// be conservative about *missing* speech rather than about false alarms,
/// since a false alarm costs a wasted inference and a miss costs words.
public struct EnergyVoiceDetector: Sendable, Equatable {
    /// Below this RMS (~ -44 dBFS) nothing counts as speech, whatever the
    /// noise floor says. Guards against a dead-quiet room where the floor
    /// would otherwise drop to ~0 and make breathing count as speech.
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

    public private(set) var noiseFloor: Float
    public private(set) var lastLevel: Float = 0

    public init(
        absoluteThreshold: Float = 0.006,
        noiseFloorRatio: Float = 2.5,
        floorFallRate: Float = 0.3,
        floorRiseRate: Float = 0.02,
        maximumNoiseFloor: Float = 0.02,
        initialNoiseFloor: Float = 0.002
    ) {
        self.absoluteThreshold = absoluteThreshold
        self.noiseFloorRatio = noiseFloorRatio
        self.floorFallRate = floorFallRate
        self.floorRiseRate = floorRiseRate
        self.maximumNoiseFloor = maximumNoiseFloor
        self.noiseFloor = initialNoiseFloor
    }

    public var threshold: Float {
        max(absoluteThreshold, noiseFloor * noiseFloorRatio)
    }

    /// Classifies one chunk and updates the noise floor. Only chunks that
    /// are *not* speech feed the floor, which is what keeps a long
    /// monologue from being reclassified as background noise.
    @discardableResult
    public mutating func isSpeech(_ samples: [Float]) -> Bool {
        let level = Self.rms(samples)
        lastLevel = level
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

    public static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples {
            sum += sample * sample
        }
        return (sum / Float(samples.count)).squareRoot()
    }

    /// Maps an RMS level to 0...1 for a meter, on a decibel scale from
    /// -50 dBFS (silent) to 0 dBFS (clipping), which is how loudness is
    /// actually perceived.
    public static func meterLevel(forRMS rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let decibels = 20 * log10(rms)
        return min(max((decibels + 50) / 50, 0), 1)
    }
}
