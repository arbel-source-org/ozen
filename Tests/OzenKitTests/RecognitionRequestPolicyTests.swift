import Testing
@testable import OzenKit

@Suite("RecognitionRequestPolicy")
struct RecognitionRequestPolicyTests {
    private func seconds(_ value: Double) -> Int { RecognitionRequestPolicy.samples(value) }

    @Test("a pause after speech ends the utterance, but a pause before any speech doesn't")
    func pause() {
        #expect(RecognitionRequestPolicy.rollover(samplesInRequest: seconds(4), samplesSinceSpeech: seconds(1.2), requestHasSpeech: true) == .pauseAfterSpeech)
        #expect(RecognitionRequestPolicy.rollover(samplesInRequest: seconds(4), samplesSinceSpeech: seconds(1.1), requestHasSpeech: true) == nil)
        #expect(RecognitionRequestPolicy.rollover(samplesInRequest: seconds(4), samplesSinceSpeech: seconds(4), requestHasSpeech: false) == nil)
    }

    @Test("a long unbroken utterance is cut at the request limit")
    func tooLong() {
        #expect(RecognitionRequestPolicy.rollover(samplesInRequest: seconds(45), samplesSinceSpeech: 0, requestHasSpeech: true) == .tooLong)
    }

    @Test("silence restarts the request before the recognizer can time out")
    func idle() {
        #expect(RecognitionRequestPolicy.rollover(samplesInRequest: seconds(8), samplesSinceSpeech: seconds(8), requestHasSpeech: false) == .idle)
        #expect(RecognitionRequestPolicy.rollover(samplesInRequest: seconds(7.9), samplesSinceSpeech: seconds(7.9), requestHasSpeech: false) == nil)
    }

    @Test("errors from requests already ended on purpose are ignored")
    func oldRequest() {
        #expect(RecognitionRequestPolicy.respond(isCurrentRequest: false, requestHadSpeech: true, requestAudioSeconds: 0.1, consecutiveFailures: 2) == .ignore)
    }

    @Test("a quiet room timing out is not a strike, however many times it happens")
    func quietRoom() {
        for strikes in 0..<10 {
            #expect(RecognitionRequestPolicy.respond(isCurrentRequest: true, requestHadSpeech: false, requestAudioSeconds: 5, consecutiveFailures: strikes) == .restartQuietly)
        }
    }

    @Test("failing mid-speech or failing instantly counts, and the third strike gives up")
    func strikes() {
        #expect(RecognitionRequestPolicy.respond(isCurrentRequest: true, requestHadSpeech: true, requestAudioSeconds: 6, consecutiveFailures: 0) == .restartCounting)
        #expect(RecognitionRequestPolicy.respond(isCurrentRequest: true, requestHadSpeech: false, requestAudioSeconds: 0.3, consecutiveFailures: 1) == .restartCounting)
        #expect(RecognitionRequestPolicy.respond(isCurrentRequest: true, requestHadSpeech: false, requestAudioSeconds: 0.3, consecutiveFailures: 2) == .giveUp)
    }
}
