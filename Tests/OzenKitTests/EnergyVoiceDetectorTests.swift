import Testing
@testable import OzenKit
import Foundation

@Suite("EnergyVoiceDetector")
struct EnergyVoiceDetectorTests {
    private func tone(amplitude: Float, count: Int = 1_024) -> [Float] {
        (0..<count).map { i in amplitude * sin(Float(i) * 0.3) }
    }

    @Test("silence is not speech, a normal speaking level is")
    func basicClassification() {
        var detector = EnergyVoiceDetector()
        let silence = detector.isSpeech([Float](repeating: 0, count: 1_024))
        let whisperQuiet = detector.isSpeech(tone(amplitude: 0.002))
        let speaking = detector.isSpeech(tone(amplitude: 0.05))
        #expect(!silence)
        #expect(!whisperQuiet)
        #expect(speaking)
    }

    @Test("a long stretch of continuous speech stays classified as speech")
    func sustainedSpeechDoesNotBecomeNoise() {
        var detector = EnergyVoiceDetector()
        var speechChunks = 0
        for _ in 0..<500 {
            if detector.isSpeech(tone(amplitude: 0.05)) { speechChunks += 1 }
        }
        #expect(speechChunks == 500)
        #expect(detector.noiseFloor <= 0.002)
    }

    @Test("the floor rises toward a steady background hum so that hum stops counting as speech")
    func floorAdaptsToHum() {
        var detector = EnergyVoiceDetector(absoluteThreshold: 0.001)
        // A hum whose RMS (amplitude / √2 ≈ 0.0064) sits just above the
        // initial threshold (0.002 × 2.5 = 0.005).
        let hum = tone(amplitude: 0.009)
        let humAtFirst = detector.isSpeech(hum)
        #expect(humAtFirst)
        // It never enters the floor while classified as speech, so the
        // detector can only adapt through quieter moments between - real
        // rooms aren't perfectly constant. Dips at RMS ≈ 0.0035 are below
        // threshold, so they feed the floor up toward ~0.0035, which lifts
        // the threshold to ~0.0088: above the hum, below speech.
        for _ in 0..<300 {
            detector.isSpeech(tone(amplitude: 0.005))
        }
        let humLater = detector.isSpeech(hum)
        let speechLater = detector.isSpeech(tone(amplitude: 0.05))
        #expect(!humLater)
        #expect(speechLater)
    }

    @Test("the floor is capped so a loud fan can't disable detection")
    func floorIsCapped() {
        var detector = EnergyVoiceDetector()
        for _ in 0..<1_000 {
            detector.isSpeech(tone(amplitude: 0.004))
        }
        #expect(detector.noiseFloor <= detector.maximumNoiseFloor)
        let loud = detector.isSpeech(tone(amplitude: 0.2))
        #expect(loud)
    }

    @Test("the floor falls quickly when the room gets quieter")
    func floorFallsFast() {
        var detector = EnergyVoiceDetector(initialNoiseFloor: 0.02)
        for _ in 0..<20 {
            detector.isSpeech([Float](repeating: 0, count: 1_024))
        }
        #expect(detector.noiseFloor < 0.001)
    }

    @Test("rms and meter level behave at the edges")
    func rmsAndMeter() {
        #expect(EnergyVoiceDetector.rms([]) == 0)
        #expect(abs(EnergyVoiceDetector.rms([1, -1, 1, -1]) - 1) < 0.0001)
        #expect(EnergyVoiceDetector.meterLevel(forRMS: 0) == 0)
        #expect(EnergyVoiceDetector.meterLevel(forRMS: 1) == 1)
        let mid = EnergyVoiceDetector.meterLevel(forRMS: 0.0316) // ≈ -30 dBFS
        #expect(mid > 0.35 && mid < 0.45)
        #expect(EnergyVoiceDetector.meterLevel(forRMS: 0.00001) == 0)
    }
}
