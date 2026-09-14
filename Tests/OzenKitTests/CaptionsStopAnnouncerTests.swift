import Testing
@testable import OzenKit

@Suite("Telling VoiceOver users that captions stopped or came back")
struct CaptionsStopAnnouncerTests {
    private let stalled = PipelinePhase.failed(PipelineFailure(kind: .audioSessionFailed, detail: "stalled"))
    private let preparing = PipelinePhase.preparingEngine(EnginePreparationProgress(stage: .loadingModel))

    @Test("a failure is announced once through its retries, and the return to listening after it")
    func failureAndRecovery() {
        var announcer = CaptionsStopAnnouncer()
        let events = [
            PipelinePhase.startingAudio, .listening,
            stalled, preparing,
            .failed(PipelineFailure(kind: .noAudioInputs, detail: "")),
            .startingAudio, .listening, .listening,
        ].map { announcer.phaseChanged(to: $0) }
        #expect(events == [nil, nil, .stopped, nil, nil, nil, .back, nil])
    }

    @Test("starting, pausing and stopping on purpose announce nothing")
    func onPurpose() {
        var announcer = CaptionsStopAnnouncer()
        let events = [PipelinePhase.requestingMicrophonePermission, preparing, .startingAudio, .listening, .paused, .listening, .idle]
            .map { announcer.phaseChanged(to: $0) }
        #expect(events.allSatisfy { $0 == nil })
    }

    @Test("stopped by hand after a failure, starting again later isn't a recovery")
    func stoppedAfterFailure() {
        var announcer = CaptionsStopAnnouncer()
        #expect(announcer.phaseChanged(to: stalled) == .stopped)
        #expect(announcer.phaseChanged(to: .idle) == nil)
        #expect(announcer.phaseChanged(to: .listening) == nil)
        #expect(announcer.phaseChanged(to: stalled) == .stopped)
    }
}
