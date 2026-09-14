import Testing
@testable import OzenKit

@Suite("SpeechPauseCoordinator")
struct SpeechPauseCoordinatorTests {
    @Test("speaking over live captions pauses them, and they return once speech settles")
    func simpleRoundTrip() {
        var coordinator = SpeechPauseCoordinator()
        let pause = coordinator.willSpeak(captionsListening: true)
        #expect(pause)
        let generation = coordinator.speechWentQuiet()
        #expect(generation != nil)
        let resume = coordinator.shouldResume(generation: generation ?? -1, synthesizerBusy: false, captionsPaused: true)
        #expect(resume)
        #expect(coordinator.isHoldingCaptions == false)
    }

    @Test("a second phrase tapped mid-speech keeps captions paused until the second one ends")
    func secondPhraseDuringFirst() {
        var coordinator = SpeechPauseCoordinator()
        _ = coordinator.willSpeak(captionsListening: true)
        // Second tap: captions are already paused (not listening).
        let pauseAgain = coordinator.willSpeak(captionsListening: false)
        #expect(pauseAgain == false)
        // The first utterance's cancel arrives; the second is queued.
        let afterCancel = coordinator.speechWentQuiet()
        let resumeOnCancel = coordinator.shouldResume(generation: afterCancel ?? -1, synthesizerBusy: true, captionsPaused: true)
        #expect(resumeOnCancel == false)
        #expect(coordinator.isHoldingCaptions)
        // The second utterance finishes.
        let afterFinish = coordinator.speechWentQuiet()
        let resumeOnFinish = coordinator.shouldResume(generation: afterFinish ?? -1, synthesizerBusy: false, captionsPaused: true)
        #expect(resumeOnFinish)
    }

    @Test("a quiet report that predates a newer request is ignored even if the synthesizer looks idle")
    func staleGeneration() {
        var coordinator = SpeechPauseCoordinator()
        _ = coordinator.willSpeak(captionsListening: true)
        let stale = coordinator.speechWentQuiet() ?? -1
        _ = coordinator.willSpeak(captionsListening: false)
        let resume = coordinator.shouldResume(generation: stale, synthesizerBusy: false, captionsPaused: true)
        #expect(resume == false)
        #expect(coordinator.isHoldingCaptions)
    }

    @Test("speaking while captions are off never turns them on")
    func captionsWereOff() {
        var coordinator = SpeechPauseCoordinator()
        let pause = coordinator.willSpeak(captionsListening: false)
        #expect(pause == false)
        #expect(coordinator.speechWentQuiet() == nil)
    }

    @Test("captions that finish starting up mid-phrase are held, and return when the phrase ends")
    func captionsCameOnMidPhrase() {
        var coordinator = SpeechPauseCoordinator()
        _ = coordinator.willSpeak(captionsListening: false)
        let hold = coordinator.captionsCameOnWhileSpeaking()
        #expect(hold)
        let generation = coordinator.speechWentQuiet()
        let resume = coordinator.shouldResume(generation: generation ?? -1, synthesizerBusy: false, captionsPaused: true)
        #expect(resume)
    }

    @Test("captions turned on by hand mid-phrase are not held; the next phrase asked for starts afresh")
    func captionsTurnedOnByHandMidPhrase() {
        var coordinator = SpeechPauseCoordinator()
        _ = coordinator.willSpeak(captionsListening: false)
        coordinator.userTookControl()
        let holdAfterManualStart = coordinator.captionsCameOnWhileSpeaking()
        #expect(holdAfterManualStart == false)
        #expect(coordinator.isHoldingCaptions == false)

        _ = coordinator.willSpeak(captionsListening: false)
        let holdForNewPhrase = coordinator.captionsCameOnWhileSpeaking()
        #expect(holdForNewPhrase)
    }

    @Test("a manual pause, stop or resume during speech cancels the automatic resume")
    func userTakesControl() {
        var coordinator = SpeechPauseCoordinator()
        _ = coordinator.willSpeak(captionsListening: true)
        let generation = coordinator.speechWentQuiet() ?? -1
        coordinator.userTookControl()
        let resume = coordinator.shouldResume(generation: generation, synthesizerBusy: false, captionsPaused: true)
        #expect(resume == false)
    }

    @Test("if captions are no longer paused when speech settles (restarted, failed), nothing is resumed")
    func captionsChangedMeanwhile() {
        var coordinator = SpeechPauseCoordinator()
        _ = coordinator.willSpeak(captionsListening: true)
        let generation = coordinator.speechWentQuiet() ?? -1
        let resume = coordinator.shouldResume(generation: generation, synthesizerBusy: false, captionsPaused: false)
        #expect(resume == false)
        #expect(coordinator.isHoldingCaptions == false)
    }
}
