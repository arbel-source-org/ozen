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

    @Test("a full phone says how much room to free, and a tap opens the model choice")
    func notEnoughStorage() {
        let presentation = PhasePresentation(
            phase: failure(EngineUnavailability(kind: .notEnoughStorage, detail: "", downloadMegabytes: 626, missingMegabytes: 1_300)),
            engine: .whisperKit,
            interruptedBySystem: false
        )
        #expect(presentation.action == .openEngineSettings)
        #expect(presentation.detail?.contains("1.3 GB") == true)
        #expect(presentation.tint == .red)
    }

    @Test("cloud captions without a usable key or credit send the person to Settings; no internet offers a retry")
    func cloudFailures() {
        let key = PhasePresentation(phase: failure(EngineUnavailability(kind: .cloudKeyNeeded, detail: "")), engine: .cloud, interruptedBySystem: false)
        let credit = PhasePresentation(phase: failure(EngineUnavailability(kind: .cloudOutOfCredit, detail: "")), engine: .cloud, interruptedBySystem: false)
        let offline = PhasePresentation(phase: failure(EngineUnavailability(kind: .noInternet, detail: "")), engine: .cloud, interruptedBySystem: false)
        #expect(key.action == .openEngineSettings)
        #expect(key.title.contains("OpenRouter"))
        #expect(credit.action == .openEngineSettings)
        #expect(offline.action == .retry)
        #expect(key.isBusy == false)
    }

    @Test("paused while the phone talks says so, and that captions come back by themselves")
    func pausedForSpeech() {
        let speaking = PhasePresentation(phase: .paused, engine: .whisperKit, interruptedBySystem: false, pausedForSpeech: true)
        #expect(speaking.title == "הטלפון מדבר")
        #expect(speaking.action == .stopSpeaking)
        let byHand = PhasePresentation(phase: .paused, engine: .whisperKit, interruptedBySystem: false)
        #expect(byHand.title == "מושהה")
    }

    @Test("sizes read as MB below a gigabyte and as GB with one decimal above")
    func sizeText() {
        #expect(PhasePresentation.sizeText(megabytes: 450) == "450 MB")
        #expect(PhasePresentation.sizeText(megabytes: 999) == "999 MB")
        #expect(PhasePresentation.sizeText(megabytes: 1_000) == "1.0 GB")
        #expect(PhasePresentation.sizeText(megabytes: 1_300) == "1.3 GB")
        // Rounded up: freeing 1.3 GB would leave it a megabyte short.
        #expect(PhasePresentation.sizeText(megabytes: 1_301) == "1.4 GB")
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

        let timed = PhasePresentation(
            phase: .preparingEngine(EnginePreparationProgress(stage: .downloadingModel, fraction: 0.42, detail: "small")),
            engine: .whisperKit,
            interruptedBySystem: false,
            downloadSecondsRemaining: 200
        )
        #expect(timed.detail?.hasPrefix("עוד כ-3 דקות · ") == true)
    }

    @Test("time left reads as words, never falsely precise")
    func remainingText() {
        #expect(PhasePresentation.remainingText(seconds: 20) == "עוד פחות מדקה")
        #expect(PhasePresentation.remainingText(seconds: 75) == "עוד כדקה")
        #expect(PhasePresentation.remainingText(seconds: 125) == "עוד כשתי דקות")
        #expect(PhasePresentation.remainingText(seconds: 1_500) == "עוד כ-25 דקות")
        #expect(PhasePresentation.remainingText(seconds: 3_600) == "עוד יותר משעה")
    }
}

/// Small pieces of wording she reads on the screen.
@Suite("Screen wording")
@MainActor
struct ScreenWordingTests {
    @Test("minutes ago reads naturally in Hebrew for one, two and more")
    func minutesAgo() {
        #expect(LiveCaptionView.minutesAgoText(0) == "לפני דקה")
        #expect(LiveCaptionView.minutesAgoText(1) == "לפני דקה")
        #expect(LiveCaptionView.minutesAgoText(2) == "לפני שתי דקות")
        #expect(LiveCaptionView.minutesAgoText(7) == "לפני 7 דקות")
    }

    @Test("the auto-delete warning counts one and two conversations in words")
    func expiryWarning() {
        #expect(HistoryView.expiryWarning(count: 1) == "שיחה ישנה אחת תימחק עכשיו")
        #expect(HistoryView.expiryWarning(count: 2) == "שתי שיחות ישנות יימחקו עכשיו")
        #expect(HistoryView.expiryWarning(count: 12) == "12 שיחות ישנות יימחקו עכשיו")
    }

    @Test("every auto-delete choice has its own name")
    func retentionNames() {
        let names = HistoryRetention.allCases.map(HistoryView.name(for:))
        #expect(Set(names).count == HistoryRetention.allCases.count)
        #expect(HistoryView.name(for: .forever) == "אף פעם")
    }
}
