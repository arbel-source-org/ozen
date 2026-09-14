import Foundation
import Testing
@testable import OzenKit

@Suite("StoppedCaptionsNotice")
struct StoppedCaptionsNoticeTests {
    private let glitch = PipelineFailure(kind: .transcriptionStopped, detail: "stream ended")

    private func engineFailure(_ kind: EngineUnavailability.Kind) -> PipelineFailure {
        PipelineFailure(kind: .engineUnavailable, detail: "", engineUnavailability: EngineUnavailability(kind: kind, detail: ""))
    }

    private func cause(
        _ phase: PipelinePhase,
        retryScheduled: Bool = false,
        interrupted: Bool = false,
        callEnded: Bool = false
    ) -> StoppedCaptionsNotice.Cause? {
        StoppedCaptionsNotice.cause(
            phase: phase,
            retryScheduled: retryScheduled,
            systemInterrupted: interrupted,
            callEndedDuringInterruption: callEnded
        )
    }

    @Test("a failure nothing will retry is a stop; one with a retry lined up is not")
    func failureWithoutRetry() {
        #expect(cause(.failed(glitch)) == .failed(glitch))
        #expect(cause(.failed(glitch), retryScheduled: true) == nil)
    }

    @Test("running, starting, paused or stopped on purpose is not a stop")
    func notStopped() {
        #expect(cause(.listening) == nil)
        #expect(cause(.startingAudio) == nil)
        #expect(cause(.paused) == nil)
        #expect(cause(.idle) == nil)
    }

    @Test("waiting for Wi-Fi starts by itself, so it is not a stop")
    func waitingForWiFi() {
        #expect(cause(.failed(engineFailure(.waitingForWiFi))) == nil)
        #expect(cause(.failed(engineFailure(.notEnoughStorage))) == .failed(engineFailure(.notEnoughStorage)))
    }

    @Test("during a call nothing is a stop; after it, a microphone that never came back is")
    func calls() {
        #expect(cause(.listening, interrupted: true) == nil)
        #expect(cause(.failed(glitch), interrupted: true) == nil)
        #expect(cause(.listening, interrupted: true, callEnded: true) == .callEnded)
        #expect(cause(.failed(glitch), interrupted: true, callEnded: true) == .callEnded)
        // Paused before the call: nothing was running to stop.
        #expect(cause(.paused, interrupted: true, callEnded: true) == nil)
    }

    @Test("posted once while the phone is put away, never while the app is on screen or switched off")
    func postsOnce() {
        var notice = StoppedCaptionsNotice()
        #expect(notice.update(for: .failed(glitch), appIsActive: true, isEnabled: true) == nil)
        #expect(notice.update(for: .failed(glitch), appIsActive: false, isEnabled: false) == nil)

        guard case .post(let content) = notice.update(for: .failed(glitch), appIsActive: false, isEnabled: true) else {
            Issue.record("expected a notification")
            return
        }
        #expect(content.identifier == StoppedCaptionsNotice.identifier)
        #expect(content.title == "הכתוביות נעצרו")
        #expect(notice.update(for: .failed(glitch), appIsActive: false, isEnabled: true) == nil)
        #expect(notice.update(for: .callEnded, appIsActive: false, isEnabled: true) == nil)
    }

    @Test("once captions run again the notice is withdrawn, and a later stop is told again")
    func withdrawsAndRearms() {
        var notice = StoppedCaptionsNotice()
        #expect(notice.update(for: nil, appIsActive: false, isEnabled: true) == nil)
        _ = notice.update(for: .callEnded, appIsActive: false, isEnabled: true)

        #expect(notice.update(for: nil, appIsActive: false, isEnabled: true) == .withdraw(identifier: StoppedCaptionsNotice.identifier))
        #expect(notice.update(for: nil, appIsActive: false, isEnabled: true) == nil)

        if case .post = notice.update(for: .failed(glitch), appIsActive: false, isEnabled: true) {} else {
            Issue.record("a new stop after recovering should notify again")
        }
    }

    @Test("opening the app while captions are still stopped takes the notice away, without posting it again later")
    func withdrawnOnScreen() {
        var notice = StoppedCaptionsNotice()
        _ = notice.update(for: .failed(glitch), appIsActive: false, isEnabled: true)
        #expect(notice.update(for: .failed(glitch), appIsActive: true, isEnabled: true) == .withdraw(identifier: StoppedCaptionsNotice.identifier))
        #expect(notice.update(for: .failed(glitch), appIsActive: true, isEnabled: true) == nil)
        #expect(notice.update(for: .failed(glitch), appIsActive: false, isEnabled: true) == nil)

        // Captions ran again, then stopped again: that's news.
        #expect(notice.update(for: nil, appIsActive: true, isEnabled: true) == nil)
        if case .post = notice.update(for: .callEnded, appIsActive: false, isEnabled: true) {} else {
            Issue.record("a new stop after recovering should notify again")
        }
    }

    @Test("the message says what she can do about it")
    func wording() {
        let callEnded = StoppedCaptionsNotice.content(for: .callEnded).body
        let permission = StoppedCaptionsNotice.content(for: .failed(PipelineFailure(kind: .microphonePermissionDenied, detail: ""))).body
        let speechPermission = StoppedCaptionsNotice.content(for: .failed(engineFailure(.permissionDenied))).body
        let storage = StoppedCaptionsNotice.content(for: .failed(engineFailure(.notEnoughStorage))).body
        let noMic = StoppedCaptionsNotice.content(for: .failed(PipelineFailure(kind: .noAudioInputs, detail: ""))).body
        let other = StoppedCaptionsNotice.content(for: .failed(glitch)).body

        #expect(callEnded.contains("אחרי השיחה"))
        #expect(permission == speechPermission)
        #expect(permission.contains("הרשאה"))
        #expect(storage.contains("מקום"))
        #expect(noMic.contains("מיקרופון"))
        #expect(Set([callEnded, permission, storage, noMic, other]).count == 5)
    }
}

@Suite("CaptionPipeline phase change callback")
@MainActor
struct CaptionPipelinePhaseChangeTests {
    @Test("each step is reported once, not every bit of download progress")
    func reportsSteps() async {
        let engine = FakeEngine(progressUpdates: [
            EnginePreparationProgress(stage: .downloadingModel, fraction: 0.1),
            EnginePreparationProgress(stage: .downloadingModel, fraction: 0.5),
            EnginePreparationProgress(stage: .downloadingModel, fraction: 0.9),
        ])
        let pipeline = CaptionPipeline(
            audio: FakeAudioCapturer(),
            engineFactory: { _ in engine },
            embedder: FakeEmbedder(),
            recovery: .disabled,
            audioWatchdog: .disabled
        )
        var reported: [String] = []
        pipeline.onPhaseChange = { phase in
            switch phase {
            case .idle: reported.append("idle")
            case .requestingMicrophonePermission: reported.append("permission")
            case .preparingEngine: reported.append("preparing")
            case .startingAudio: reported.append("audio")
            case .listening: reported.append("listening")
            case .paused: reported.append("paused")
            case .failed: reported.append("failed")
            }
        }

        await pipeline.start(settings: .default)
        try? await Task.sleep(for: .milliseconds(100))
        pipeline.pause()

        #expect(reported == ["permission", "preparing", "audio", "listening", "paused"])
    }
}
