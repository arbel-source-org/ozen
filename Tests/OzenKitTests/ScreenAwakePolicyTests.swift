import Testing
@testable import OzenKit

@Suite("Screen awake policy")
struct ScreenAwakePolicyTests {
    @Test("preparing the model always keeps the screen on, whatever the setting or the quiet")
    func preparing() {
        for phase: PipelinePhase in [
            .requestingMicrophonePermission,
            .preparingEngine(EnginePreparationProgress(stage: .downloadingModel, fraction: 0.1)),
            .preparingEngine(EnginePreparationProgress(stage: .loadingModel)),
            .startingAudio,
        ] {
            #expect(ScreenAwakePolicy.shouldKeepAwake(phase: phase, keepAwakeWhileListening: false))
            #expect(ScreenAwakePolicy.shouldKeepAwake(phase: phase, keepAwakeWhileListening: true, lastActivityAt: 0, now: 10_000))
        }
    }

    @Test("listening follows the setting; idle, paused and failed let the phone lock")
    func otherPhases() {
        #expect(ScreenAwakePolicy.shouldKeepAwake(phase: .listening, keepAwakeWhileListening: true))
        #expect(ScreenAwakePolicy.shouldKeepAwake(phase: .listening, keepAwakeWhileListening: false) == false)
        for phase: PipelinePhase in [.idle, .paused, .failed(PipelineFailure(kind: .audioSessionFailed, detail: ""))] {
            #expect(ScreenAwakePolicy.shouldKeepAwake(phase: phase, keepAwakeWhileListening: true) == false)
        }
    }

    @Test("while listening the screen stays on during talk, and may lock after a long quiet")
    func quietLetsThePhoneLock() {
        let quiet = ScreenAwakePolicy.quietLockSeconds
        let lastWords: Double = 1_000
        #expect(ScreenAwakePolicy.shouldKeepAwake(phase: .listening, keepAwakeWhileListening: true, lastActivityAt: lastWords, now: lastWords + 60))
        #expect(ScreenAwakePolicy.shouldKeepAwake(phase: .listening, keepAwakeWhileListening: true, lastActivityAt: lastWords, now: lastWords + quiet - 1))
        #expect(ScreenAwakePolicy.shouldKeepAwake(phase: .listening, keepAwakeWhileListening: true, lastActivityAt: lastWords, now: lastWords + quiet) == false)
        #expect(ScreenAwakePolicy.shouldKeepAwake(phase: .listening, keepAwakeWhileListening: true, lastActivityAt: lastWords, now: lastWords + 8 * 3_600) == false)
        #expect(quiet >= 10 * 60)
    }
}
