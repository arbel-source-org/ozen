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

    @Test("steady noise lowers the margin speech needs to 6 dB; noise that swings keeps it at 8 dB")
    func marginFollowsHowTheNoiseSwings() {
        var steady = EnergyVoiceDetector()
        #expect(abs(steady.currentNoiseFloorRatio - 2.5) < 0.01)
        let hum = tone(amplitude: 0.002, count: 1_600)
        for _ in 0..<600 {
            steady.isSpeech(hum)
        }
        #expect(steady.noiseSwingDecibels < 0.5)
        #expect(steady.currentNoiseFloorRatio < 2.15)
        // Six decibels above the hum: speech with the lower margin.
        let justAbove = steady.isSpeech(tone(amplitude: 0.0042, count: 1_600))
        #expect(justAbove)

        var swinging = EnergyVoiceDetector()
        for i in 0..<600 {
            let decibels = Float((i * 7) % 13) - 6
            swinging.isSpeech(tone(amplitude: 0.002 * pow(10, decibels / 20), count: 1_600))
        }
        #expect(swinging.noiseSwingDecibels > 2)
        #expect(abs(swinging.currentNoiseFloorRatio - 2.5) < 0.01)
    }

    @Test("a window only a few chunks long can't tell how the noise swings, so the margin stays cautious")
    func fewChunksKeepTheMargin() {
        var detector = EnergyVoiceDetector(recentWindowSamples: 3_200)
        for i in 0..<600 {
            detector.isSpeech(tone(amplitude: i % 2 == 0 ? 0.001 : 0.004, count: 1_600))
        }
        #expect(abs(detector.currentNoiseFloorRatio - 2.5) < 0.01)
    }

    @Test("a glitched chunk, NaN or infinite, is not speech and doesn't stop the floor from following a hum")
    func glitchedChunksAreIgnored() {
        var detector = EnergyVoiceDetector()
        let hum = tone(amplitude: 0.009)
        // Wholly corrupted, not just a single bad sample among mostly-good
        // ones (a single stray sample is now tolerated; see
        // oneBadSampleDoesNotHideSpeech).
        let notANumber = [Float](repeating: .nan, count: hum.count)
        let infinite = [Float](repeating: .infinity, count: hum.count)
        let notANumberAtFirst = detector.isSpeech(notANumber)
        for index in 0..<156 {
            detector.isSpeech(index == 80 ? infinite : hum)
        }
        let infiniteLater = detector.isSpeech(infinite)
        let humLater = detector.isSpeech(hum)
        let speechOverIt = detector.isSpeech(tone(amplitude: 0.05))
        #expect(!notANumberAtFirst && !infiniteLater)
        #expect(detector.noiseFloor.isFinite && detector.noiseSwingDecibels.isFinite)
        #expect(!humLater)
        #expect(speechOverIt)
    }

    @Test("a single corrupted sample doesn't discard an otherwise loud, real chunk")
    func oneBadSampleDoesNotHideSpeech() {
        var detector = EnergyVoiceDetector()
        var speech = tone(amplitude: 0.05)
        speech[10] = .nan
        let stillSpeech = detector.isSpeech(speech)
        #expect(stillSpeech)

        var mostlyGlitched = [Float](repeating: 0, count: 1_024)
        for i in 0..<600 { mostlyGlitched[i] = .nan }
        for i in 600..<1_024 { mostlyGlitched[i] = 0.05 * sin(Float(i) * 0.3) }
        let notSpeech = detector.isSpeech(mostlyGlitched)
        #expect(!notSpeech)
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
