import Testing
@testable import OzenKit
import Foundation

@Suite("EnergyVoiceDetector")
struct EnergyVoiceDetectorTests {
    private func tone(amplitude: Float, count: Int = 1_024) -> [Float] {
        (0..<count).map { i in amplitude * sin(Float(i) * 0.3) }
    }

    @Test("silence is not speech; conversation as quiet as measurement mode delivers it is")
    func basicClassification() {
        var detector = EnergyVoiceDetector()
        let silence = detector.isSpeech([Float](repeating: 0, count: 1_024))
        // RMS about -65 dBFS: a quiet room.
        let room = detector.isSpeech(tone(amplitude: 0.0008))
        // RMS about -55 dBFS: someone talking across the table. Under the
        // old -44 dBFS threshold this never counted.
        let acrossTheTable = detector.isSpeech(tone(amplitude: 0.0025))
        let speaking = detector.isSpeech(tone(amplitude: 0.05))
        #expect(!silence)
        #expect(!room)
        #expect(acrossTheTable)
        #expect(speaking)
    }

    @Test("a long stretch of speech, with the short gaps speech has, stays classified as speech")
    func sustainedSpeechDoesNotBecomeNoise() {
        var detector = EnergyVoiceDetector()
        var words = 0
        var wordsHeard = 0
        // 1024-sample chunks are 64 ms: words of about 320 ms between gaps
        // of about 130 ms, for over three minutes.
        for index in 0..<3_000 {
            if index % 7 < 5 {
                words += 1
                if detector.isSpeech(tone(amplitude: 0.01)) { wordsHeard += 1 }
            } else {
                detector.isSpeech(tone(amplitude: 0.0005))
            }
        }
        #expect(wordsHeard == words)
        #expect(detector.noiseFloor < 0.001)
    }

    @Test("a steady hum louder than the threshold stops counting as speech within seconds, with no quieter moments")
    func floorAdaptsToHum() {
        var detector = EnergyVoiceDetector()
        // RMS about -44 dBFS: a fridge or an air conditioner near the phone.
        let hum = tone(amplitude: 0.009)
        let humAtFirst = detector.isSpeech(hum)
        #expect(humAtFirst)
        // Ten seconds of nothing but the hum.
        for _ in 0..<156 {
            detector.isSpeech(hum)
        }
        let humLater = detector.isSpeech(hum)
        let speechOverIt = detector.isSpeech(tone(amplitude: 0.05))
        #expect(!humLater)
        #expect(speechOverIt)
    }

    @Test("without the recent-minimum rule a steady hum would count as speech for good")
    func humWithoutRecentMinimum() {
        var detector = EnergyVoiceDetector(recentWindowSamples: 0)
        let hum = tone(amplitude: 0.009)
        for _ in 0..<156 {
            detector.isSpeech(hum)
        }
        let humLater = detector.isSpeech(hum)
        #expect(humLater)
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
        #expect(mid > 0.52 && mid < 0.62)
        // Conversation at -55 dBFS moves the meter; a -80 dBFS room doesn't.
        #expect(EnergyVoiceDetector.meterLevel(forRMS: 0.0018) > 0.15)
        #expect(EnergyVoiceDetector.meterLevel(forRMS: 0.0001) == 0)
    }
}
