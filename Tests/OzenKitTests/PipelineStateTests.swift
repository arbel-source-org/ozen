import Testing
@testable import OzenKit

@Suite("PipelinePhase and PipelineFailure")
struct PipelineStateTests {
    @Test("only the startup steps count as transitioning")
    func transitioning() {
        #expect(PipelinePhase.requestingMicrophonePermission.isTransitioning)
        #expect(PipelinePhase.preparingEngine(EnginePreparationProgress(stage: .loadingModel)).isTransitioning)
        #expect(PipelinePhase.startingAudio.isTransitioning)
        #expect(!PipelinePhase.idle.isTransitioning)
        #expect(!PipelinePhase.listening.isTransitioning)
        #expect(!PipelinePhase.paused.isTransitioning)
        #expect(!PipelinePhase.failed(PipelineFailure(kind: .noAudioInputs, detail: "")).isTransitioning)
    }

    @Test("accessors unwrap the associated values")
    func accessors() {
        let progress = EnginePreparationProgress(stage: .downloadingModel, fraction: 0.5)
        #expect(PipelinePhase.preparingEngine(progress).preparationProgress == progress)
        #expect(PipelinePhase.listening.preparationProgress == nil)
        let failure = PipelineFailure(kind: .audioSessionFailed, detail: "x")
        #expect(PipelinePhase.failed(failure).failure == failure)
        #expect(PipelinePhase.listening.failure == nil)
        #expect(PipelinePhase.listening.isListening)
    }

    @Test("retryability follows the kind of failure, and permission denials point to system Settings")
    func retryability() {
        #expect(!PipelineFailure(kind: .microphonePermissionDenied, detail: "").isRetryableInApp)
        #expect(PipelineFailure(kind: .microphonePermissionDenied, detail: "").needsSystemSettings)
        #expect(PipelineFailure(kind: .audioSessionFailed, detail: "").isRetryableInApp)
        #expect(PipelineFailure(kind: .transcriptionStopped, detail: "").isRetryableInApp)
        #expect(PipelineFailure(kind: .noAudioInputs, detail: "").isRetryableInApp)

        let speechDenied = PipelineFailure(
            kind: .engineUnavailable, detail: "",
            engineUnavailability: EngineUnavailability(kind: .permissionDenied, detail: "")
        )
        #expect(!speechDenied.isRetryableInApp)
        let downloadFailed = PipelineFailure(
            kind: .engineUnavailable, detail: "",
            engineUnavailability: EngineUnavailability(kind: .modelDownloadFailed, detail: "")
        )
        #expect(downloadFailed.isRetryableInApp)
    }

    @Test("suggesting the other engine only makes sense for engine-specific gaps")
    func otherEngineSuggestion() {
        func failure(_ kind: EngineUnavailability.Kind) -> PipelineFailure {
            PipelineFailure(kind: .engineUnavailable, detail: "", engineUnavailability: EngineUnavailability(kind: kind, detail: ""))
        }
        #expect(failure(.languageNotSupportedOnDevice).suggestsOtherEngine)
        #expect(failure(.modelDownloadFailed).suggestsOtherEngine)
        #expect(failure(.modelLoadFailed).suggestsOtherEngine)
        #expect(!failure(.permissionDenied).suggestsOtherEngine)
        #expect(!failure(.temporarilyUnavailable).suggestsOtherEngine)
        #expect(failure(.noInternet).suggestsOtherEngine)
        #expect(!failure(.cloudKeyNeeded).suggestsOtherEngine)
        #expect(!failure(.cloudOutOfCredit).suggestsOtherEngine)
        #expect(!PipelineFailure(kind: .audioSessionFailed, detail: "").suggestsOtherEngine)
    }

    @Test("caption lag is the gap between newest audio and newest token, never negative")
    func captionLag() {
        var stats = PipelineStats()
        #expect(stats.captionLagSeconds == nil)
        stats.lastAudioAt = 100
        stats.lastTokenAt = 99.2
        stats.hasOpenLine = true
        #expect(stats.captionLagSeconds != nil)
        #expect(abs((stats.captionLagSeconds ?? 0) - 0.8) < 0.0001)
        stats.lastTokenAt = 101
        #expect(stats.captionLagSeconds == 0)
    }

    @Test("EngineAvailability convenience constructor and accessor")
    func availabilityHelpers() {
        let availability = EngineAvailability.unavailable(.modelLoadFailed, "boom")
        #expect(availability.unavailability?.kind == .modelLoadFailed)
        #expect(availability.unavailability?.detail == "boom")
        #expect(EngineAvailability.available.unavailability == nil)
    }

    @Test("a phase's step keeps the stage and model of a download but not how far along it is")
    func stepIgnoresDownloadFraction() {
        let at10 = PipelinePhase.preparingEngine(EnginePreparationProgress(stage: .downloadingModel, fraction: 0.1, detail: "small"))
        let at11 = PipelinePhase.preparingEngine(EnginePreparationProgress(stage: .downloadingModel, fraction: 0.11, detail: "small"))
        #expect(at10 != at11)
        #expect(at10.step == at11.step)
        #expect(at10.step != PipelinePhase.preparingEngine(EnginePreparationProgress(stage: .loadingModel, detail: "small")).step)
        #expect(at10.step != PipelinePhase.preparingEngine(EnginePreparationProgress(stage: .downloadingModel, fraction: 0.1, detail: "base")).step)
        #expect(PipelinePhase.listening.step == .listening)
        #expect(PipelinePhase.failed(PipelineFailure(kind: .audioSessionFailed, detail: "x")).step == .failed(PipelineFailure(kind: .audioSessionFailed, detail: "x")))
    }

    @Test("a download's progress is news at another step, model or whole percent, or a second later")
    func progressNews() {
        let shown = EnginePreparationProgress(stage: .downloadingModel, fraction: 0.421, detail: "small")
        func downloading(_ fraction: Double, _ variant: String = "small") -> EnginePreparationProgress {
            EnginePreparationProgress(stage: .downloadingModel, fraction: fraction, detail: variant)
        }
        #expect(!downloading(0.4249).isNews(after: shown, shownAt: 10, now: 10.5))
        #expect(downloading(0.426).isNews(after: shown, shownAt: 10, now: 10.5))
        #expect(downloading(0.4249).isNews(after: shown, shownAt: 10, now: 11))
        #expect(downloading(0.421, "base").isNews(after: shown, shownAt: 10, now: 10.1))
        let loading = EnginePreparationProgress(stage: .loadingModel, detail: "small")
        #expect(loading.isNews(after: shown, shownAt: 10, now: 10.1))
        #expect(!loading.isNews(after: loading, shownAt: 10, now: 50))
    }

    @Test("caption lag counts only while a line is still being written")
    func lagOnlyWhileOpen() {
        var stats = PipelineStats()
        #expect(stats.captionLagSeconds == nil)
        stats.lastTokenAt = 100
        stats.lastAudioAt = 103
        stats.hasOpenLine = true
        #expect(stats.captionLagSeconds == 3)
        stats.hasOpenLine = false
        stats.lastAudioAt = 160
        #expect(stats.captionLagSeconds == 0)
    }
}
