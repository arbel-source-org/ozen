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
        #expect(!key.title.contains("OpenRouter") && key.title.contains("בענן"))
        #expect(credit.action == .openEngineSettings)
        #expect(offline.action == .retry)
        #expect(key.isBusy == false)
    }

    @Test("what only the person who set up the phone can fix tells her to ask them, and no engine name reaches her in English")
    func familyOnlyFailures() {
        for kind in [EngineUnavailability.Kind.cloudKeyNeeded, .cloudOutOfCredit, .homeServerRejected] {
            let shown = PhasePresentation(phase: failure(EngineUnavailability(kind: kind, detail: "")), engine: .cloud, interruptedBySystem: false)
            #expect(shown.detail?.contains("ממי שהתקין את הטלפון") == true, "\(kind)")
            #expect(shown.action == .openEngineSettings)
        }
        let phone = PhasePresentation(phase: failure(EngineUnavailability(kind: .other, detail: "")), engine: .whisperKit, interruptedBySystem: false)
        #expect(!phone.title.contains("Whisper"))
    }

    @Test("the phone's own model covering for the cloud still reads as listening, and says why")
    func coveringForCloud() {
        let covering = PhasePresentation(phase: .listening, engine: .whisperKit, interruptedBySystem: false, coveringForCloud: true)
        let plain = PhasePresentation(phase: .listening, engine: .whisperKit, interruptedBySystem: false)
        #expect(covering.title == plain.title)
        #expect(covering.action == .pause)
        #expect(covering.tint == .green)
        #expect(covering.detail != plain.detail)
        #expect(covering.detail?.contains("בענן") == true)
    }

    @Test("covering for the home computer says whether it couldn't be reached or refused the pairing code")
    func coveringForHomeServer() {
        func covering(_ reason: EngineUnavailability.Kind) -> PhasePresentation {
            PhasePresentation(phase: .listening, engine: .whisperKit, interruptedBySystem: false, coveringForCloud: true, coveredEngine: .homeServer, coverReason: reason)
        }
        let unreachable = covering(.homeServerUnreachable)
        let refused = covering(.homeServerRejected)
        #expect(unreachable.detail?.contains("אין חיבור למחשב בבית") == true)
        #expect(refused.detail?.contains("קוד הצימוד") == true)
        #expect(refused.action == .openEngineSettings && refused.tint == .green)
        #expect(refused.detail?.contains("ממי שהתקין את הטלפון") == true)
        #expect(!refused.detailFitsInStatus && !unreachable.detailFitsInStatus)
    }

    @Test("a short hint stays in the status button; a long one gets its own line rather than being cut off")
    func longDetailsLeaveTheButton() {
        let listening = PhasePresentation(phase: .listening, engine: .whisperKit, interruptedBySystem: false)
        let paused = PhasePresentation(phase: .paused, engine: .whisperKit, interruptedBySystem: false)
        let setUp = PhasePresentation(phase: failure(EngineUnavailability(kind: .homeServerRejected, detail: "")), engine: .homeServer, interruptedBySystem: false)
        #expect(listening.detailFitsInStatus && paused.detailFitsInStatus)
        #expect(!setUp.detailFitsInStatus)
        let nothing = PhasePresentation(phase: .startingAudio, engine: .whisperKit, interruptedBySystem: false)
        #expect(nothing.detail == nil && nothing.detailFitsInStatus)
    }

    @Test("covering for the cloud sends the family to Settings when only they can fix it, and offers nothing to fix for no internet")
    func coveringForCloudActionableReasons() {
        func covering(_ reason: EngineUnavailability.Kind) -> PhasePresentation {
            PhasePresentation(phase: .listening, engine: .whisperKit, interruptedBySystem: false, coveringForCloud: true, coveredEngine: .cloud, coverReason: reason)
        }
        let noKey = covering(.cloudKeyNeeded)
        let noCredit = covering(.cloudOutOfCredit)
        let offline = covering(.noInternet)
        #expect(noKey.detail?.contains("OpenRouter") == false && noKey.detail?.contains("ממי שהתקין את הטלפון") == true)
        #expect(noKey.action == .openEngineSettings && noKey.tint == .green)
        #expect(noCredit.detail?.contains("התקציב") == true)
        #expect(noCredit.action == .openEngineSettings && noCredit.tint == .green)
        // No internet still just says so and lets her keep going: nothing
        // in Settings would fix a dropped connection.
        #expect(offline.action == .pause)
        #expect(offline.detail?.contains("בענן") == true)
    }

    @Test("paused while the phone talks says so, and that captions come back by themselves")
    func pausedForSpeech() {
        let speaking = PhasePresentation(phase: .paused, engine: .whisperKit, interruptedBySystem: false, pausedForSpeech: true)
        #expect(speaking.title == "הטלפון מדבר")
        #expect(speaking.action == .stopSpeaking)
        let byHand = PhasePresentation(phase: .paused, engine: .whisperKit, interruptedBySystem: false)
        #expect(byHand.title == "מושהה")
        #expect(byHand.detail == "הקישו כדי להמשיך")
        #expect(PhasePresentation(phase: .idle, engine: .whisperKit, interruptedBySystem: false).title == "הכתוביות כבויות")
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

    @Test("a phone call outranks every other state, and a tap tries to take the microphone back right now")
    func phoneCall() {
        let presentation = PhasePresentation(phase: .listening, engine: .whisperKit, interruptedBySystem: true)
        #expect(presentation.action == .resume)
        #expect(presentation.systemImage == "phone.fill")
        #expect(presentation.detail?.contains("לנסות עכשיו") == true)
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

    @Test("the first load of a model says it is a one-time wait of minutes; later loads don't")
    func firstLoad() {
        let first = PhasePresentation(
            phase: .preparingEngine(EnginePreparationProgress(stage: .loadingModel, detail: "small", isFirstTime: true)),
            engine: .whisperKit,
            interruptedBySystem: false
        )
        let later = PhasePresentation(
            phase: .preparingEngine(EnginePreparationProgress(stage: .loadingModel, detail: "small")),
            engine: .whisperKit,
            interruptedBySystem: false
        )
        #expect(first.detail?.contains("פעם אחת בלבד") == true)
        #expect(later.detail?.contains("פעם אחת בלבד") == false)
        #expect(first.title != later.title)
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

    @Test("the home-computer guide walks through four distinct steps and names the graphics card it needs")
    func homeServerGuide() {
        let steps = HomeServerGuideView.steps
        #expect(steps.map(\.id) == [1, 2, 3, 4])
        #expect(Set(steps.map(\.title)).count == 4)
        #expect(steps.allSatisfy { !$0.text.isEmpty })
        #expect(steps[0].text.contains("NVIDIA") && steps[0].text.contains("6GB"))
    }

    @Test("every auto-delete choice has its own name")
    func retentionNames() {
        let names = HistoryRetention.allCases.map(HistoryView.name(for:))
        #expect(Set(names).count == HistoryRetention.allCases.count)
        #expect(HistoryView.name(for: .forever) == "אף פעם")
    }
}
