import Testing
@testable import OzenKit

@Suite("Screen awake policy")
struct ScreenAwakePolicyTests {
    @Test("preparing the model always keeps the screen on, whatever the setting")
    func preparing() {
        for phase: PipelinePhase in [
            .requestingMicrophonePermission,
            .preparingEngine(EnginePreparationProgress(stage: .downloadingModel, fraction: 0.1)),
            .preparingEngine(EnginePreparationProgress(stage: .loadingModel)),
            .startingAudio,
        ] {
            #expect(ScreenAwakePolicy.shouldKeepAwake(phase: phase, keepAwakeWhileListening: false))
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
}
