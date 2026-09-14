import Testing
@testable import Ozen
@testable import OzenKit

/// The status line is the only thing that tells her what the app is doing,
/// so what it says for each state is pinned down here.
@Suite("Status line")
@MainActor
struct PhasePresentationTests {
    private func failure(_ why: EngineUnavailability) -> PipelinePhase {
        .failed(PipelineFailure(kind: .engineUnavailable, detail: "", engineUnavailability: why))
    }

    @Test("waiting for Wi-Fi says the size, and a tap asks before using cellular data")
    func waitingForWiFi() {
        let presentation = PhasePresentation(
            phase: failure(EngineUnavailability(kind: .waitingForWiFi, detail: "", downloadMegabytes: 626)),
            engine: .whisperKit,
            interruptedBySystem: false
        )
        #expect(presentation.action == .confirmCellularDownload)
        #expect(presentation.detail?.contains("626 MB") == true)
        #expect(presentation.isBusy == false)
    }

    @Test("an unknown model size is left out rather than shown as 0 MB")
    func waitingForWiFiUnknownSize() {
        let presentation = PhasePresentation(
            phase: failure(EngineUnavailability(kind: .waitingForWiFi, detail: "", downloadMegabytes: 0)),
            engine: .whisperKit,
            interruptedBySystem: false
        )
        #expect(presentation.detail?.contains("MB") == false)
    }

    @Test("a phone call outranks every other state and offers no action")
    func phoneCall() {
        let presentation = PhasePresentation(phase: .listening, engine: .whisperKit, interruptedBySystem: true)
        #expect(presentation.action == .none)
        #expect(presentation.systemImage == "phone.fill")
    }

    @Test("a failure with a retry on the way says so and still lets her retry now")
    func scheduledRetry() {
        let presentation = PhasePresentation(
            phase: .failed(PipelineFailure(kind: .audioSessionFailed, detail: "")),
            engine: .whisperKit,
            interruptedBySystem: false,
            scheduledRetry: ScheduledRetry(at: 0, attempt: 1)
        )
        #expect(presentation.action == .retry)
        #expect(presentation.isBusy)
        #expect(presentation.detail?.contains("מנסה שוב לבד") == true)
    }

    @Test("a denied microphone sends her to the system settings, not to a retry that can't work")
    func permissionDenied() {
        let presentation = PhasePresentation(
            phase: .failed(PipelineFailure(kind: .microphonePermissionDenied, detail: "")),
            engine: nil,
            interruptedBySystem: false
        )
        #expect(presentation.action == .openSystemSettings)
    }

    @Test("listening pauses on tap, a download shows its progress")
    func everydayStates() {
        #expect(PhasePresentation(phase: .listening, engine: .whisperKit, interruptedBySystem: false).action == .pause)
        let downloading = PhasePresentation(
            phase: .preparingEngine(EnginePreparationProgress(stage: .downloadingModel, fraction: 0.42, detail: "small")),
            engine: .whisperKit,
            interruptedBySystem: false
        )
        #expect(downloading.progress == 0.42)
        #expect(downloading.title.contains("42%"))
    }
}
