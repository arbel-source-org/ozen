import Testing
@testable import OzenKit

@MainActor
@Suite("Cloud captions handing over to the phone's own model")
struct CloudCoverTests {
    private func pipeline(cloud: FakeEngine, phone: FakeEngine) -> CaptionPipeline {
        CaptionPipeline(
            audio: FakeAudioCapturer(),
            engineFactory: { $0.engine == .cloud ? cloud : phone },
            embedder: FakeEmbedder(),
            recovery: .disabled
        )
    }

    private var cloudSettings: AppSettings {
        var settings = AppSettings.default
        settings.engine = .cloud
        return settings
    }

    @Test("out of credit, no key or no internet: the downloaded phone model carries on")
    func coversWhenAPersonIsNeeded() async {
        for kind in [EngineUnavailability.Kind.cloudOutOfCredit, .cloudKeyNeeded, .noInternet] {
            let cloud = FakeEngine(kind: .cloud, availability: .unavailable(kind, "test"))
            let phone = FakeEngine(kind: .whisperKit)
            let captions = pipeline(cloud: cloud, phone: phone)
            await captions.start(settings: cloudSettings)
            #expect(await eventually { captions.phase == .listening }, "\(kind)")
            #expect(captions.isCoveringForCloud)
            #expect(captions.activeEngineKind == .whisperKit)
            #expect(captions.activeSettings?.engine == .whisperKit)
        }
    }

    @Test("a phone model that would have to download first is not started behind her back")
    func noSurpriseDownload() async {
        let cloud = FakeEngine(kind: .cloud, availability: .unavailable(.cloudOutOfCredit, "test"))
        let phone = FakeEngine(kind: .whisperKit)
        phone.pendingDownload = 800
        let captions = pipeline(cloud: cloud, phone: phone)
        await captions.start(settings: cloudSettings)
        #expect(await eventually { phone.pendingDownloadChecks > 0 })
        #expect(captions.phase.failure?.engineUnavailability?.kind == .cloudOutOfCredit)
        #expect(!captions.isCoveringForCloud)
        #expect(phone.prepareCount == 0)
    }

    private func pipeline(cloud: FakeEngine, phone: FakeEngine, retryAfter delays: [Double]) -> CaptionPipeline {
        CaptionPipeline(
            audio: FakeAudioCapturer(),
            engineFactory: { $0.engine == .cloud ? cloud : phone },
            embedder: FakeEmbedder(),
            recovery: AutoRecoveryPolicy(glitchDelays: delays, downloadDelays: [])
        )
    }

    @Test("a passing cloud problem is retried as before, not covered")
    func passingTroubleIsNotCovered() async throws {
        let cloud = FakeEngine(kind: .cloud, availability: .unavailable(.temporarilyUnavailable, "test"))
        let phone = FakeEngine(kind: .whisperKit)
        let captions = pipeline(cloud: cloud, phone: phone, retryAfter: [60])
        await captions.start(settings: cloudSettings)
        #expect(captions.phase.failure?.engineUnavailability?.kind == .temporarilyUnavailable)
        #expect(captions.scheduledRetry != nil)
        try await Task.sleep(for: .milliseconds(200))
        #expect(phone.prepareCount == 0)
        #expect(!captions.isCoveringForCloud)
    }

    @Test("a cloud still busy after every retry is covered, not left stopped")
    func troubleOutlastingRetriesIsCovered() async {
        let cloud = FakeEngine(kind: .cloud, availability: .unavailable(.temporarilyUnavailable, "test"))
        let phone = FakeEngine(kind: .whisperKit)
        let captions = pipeline(cloud: cloud, phone: phone, retryAfter: [0.01, 0.01])
        await captions.start(settings: cloudSettings)
        #expect(await eventually { captions.phase == .listening && captions.isCoveringForCloud })
        #expect(captions.activeEngineKind == .whisperKit)
        #expect(captions.coverReason == .temporarilyUnavailable)
        #expect(cloud.prepareCount >= 3)
    }

    @Test("starting again with her own settings ends the cover")
    func restartEndsCover() async {
        let engines = [
            FakeEngine(kind: .cloud, availability: .unavailable(.noInternet, "test")),
            FakeEngine(kind: .cloud),
        ]
        let phone = FakeEngine(kind: .whisperKit)
        let cloudBuilt = BuiltEngines()
        let captions = CaptionPipeline(
            audio: FakeAudioCapturer(),
            engineFactory: { settings in
                guard settings.engine == .cloud else { return phone }
                let engine = engines[min(cloudBuilt.count, 1)]
                cloudBuilt.add(engine)
                return engine
            },
            embedder: FakeEmbedder(),
            recovery: .disabled
        )
        await captions.start(settings: cloudSettings)
        #expect(await eventually { captions.isCoveringForCloud && captions.phase == .listening })
        await captions.restart(settings: cloudSettings)
        #expect(captions.phase == .listening)
        #expect(!captions.isCoveringForCloud)
        #expect(captions.activeEngineKind == .cloud)
    }

    @Test("pausing and resuming with her cloud settings keeps the phone's model on, without building it again")
    func resumeKeepsCover() async {
        let cloud = FakeEngine(kind: .cloud, availability: .unavailable(.cloudOutOfCredit, "test"))
        let phone = FakeEngine(kind: .whisperKit)
        let built = BuiltEngines()
        let captions = CaptionPipeline(
            audio: FakeAudioCapturer(),
            engineFactory: { settings in
                let engine = settings.engine == .cloud ? cloud : phone
                built.add(engine)
                return engine
            },
            embedder: FakeEmbedder(),
            recovery: .disabled
        )
        await captions.start(settings: cloudSettings)
        #expect(await eventually { captions.isCoveringForCloud && captions.phase == .listening })
        let builtBefore = built.count
        captions.pause()
        await captions.resume(settings: cloudSettings)
        #expect(captions.phase == .listening)
        #expect(captions.isCoveringForCloud)
        #expect(captions.activeEngineKind == .whisperKit)
        #expect(built.count == builtBefore)
    }

    @Test("a home computer address changed while paused is tried on resume, instead of the phone's model covering for the old one")
    func addressChangedWhilePausedEndsCover() async {
        let old = FakeEngine(kind: .homeServer, availability: .unavailable(.homeServerUnreachable, "test"))
        let fixed = FakeEngine(kind: .homeServer)
        let phone = FakeEngine(kind: .whisperKit)
        let captions = CaptionPipeline(
            audio: FakeAudioCapturer(),
            engineFactory: { settings in
                guard settings.engine == .homeServer else { return phone }
                return settings.homeServerAddress == "10.0.0.9" ? fixed : old
            },
            embedder: FakeEmbedder(),
            recovery: .disabled
        )
        var settings = AppSettings.default
        settings.engine = .homeServer
        settings.homeServerAddress = "10.0.0.5"
        await captions.start(settings: settings)
        #expect(await eventually { captions.isCoveringForCloud && captions.phase == .listening })
        captions.pause()
        settings.homeServerAddress = "10.0.0.9"
        captions.settingsChangedWhilePaused()
        await captions.resume(settings: settings)
        #expect(captions.phase == .listening)
        #expect(!captions.isCoveringForCloud)
        #expect(captions.activeEngineKind == .homeServer)
        #expect(fixed.prepareCount == 1)
    }

    @Test("an engine already on the phone is never swapped")
    func onlyCloudIsCovered() {
        let failure = PipelineFailure(kind: .engineUnavailable, detail: "", engineUnavailability: EngineUnavailability(kind: .noInternet, detail: ""))
        #expect(CloudCover.phoneSettings(replacing: .default, after: failure) == nil)
    }

    @Test("once the internet returns, cloud captions switch back by themselves")
    func switchesBackWhenInternetReturns() async {
        let cloud = FakeEngine(kind: .cloud)
        let phone = FakeEngine(kind: .whisperKit)
        let captions = pipeline(cloud: cloud, phone: phone)
        captions.cloudRecheckSeconds = 0.05
        captions.homeServerSwitchBackQuietSeconds = 0
        await captions.start(settings: cloudSettings)
        #expect(await eventually { captions.phase == .listening && captions.activeEngineKind == .cloud })
        cloud.endStream(throwing: EngineUnavailability(kind: .noInternet, detail: "connection lost"))
        #expect(await eventually { captions.activeEngineKind == .whisperKit })
        #expect(await eventually { captions.phase == .listening && captions.activeEngineKind == .cloud })
        #expect(!captions.isCoveringForCloud)
        #expect(captions.coverReason == nil)
    }

    @Test("an alert word or a name added while the phone's model covers is still there after switching back")
    func changesDuringCoverSurviveSwitchBack() async {
        let cloud = FakeEngine(kind: .cloud)
        let phone = FakeEngine(kind: .whisperKit)
        let captions = pipeline(cloud: cloud, phone: phone)
        captions.cloudRecheckSeconds = 1
        captions.homeServerSwitchBackQuietSeconds = 0
        await captions.start(settings: cloudSettings)
        #expect(await eventually { captions.phase == .listening && captions.activeEngineKind == .cloud })
        cloud.endStream(throwing: EngineUnavailability(kind: .noInternet, detail: "connection lost"))
        #expect(await eventually { captions.phase == .listening && captions.activeEngineKind == .whisperKit })

        captions.setKeywordAlerts([KeywordAlert(phrase: "Ruti", isEnabled: true)])
        await captions.setVocabulary(["Avi"])

        #expect(await eventually { captions.phase == .listening && captions.activeEngineKind == .cloud })
        #expect(captions.activeSettings?.keywordAlerts.map(\.phrase) == ["Ruti"])
        #expect(captions.activeSettings?.vocabulary == ["Avi"])
        captions.stop()
    }

    @Test("a connection that keeps dropping right after switching back is tried less and less often; a drop after a good stretch starts over")
    func flappingCloudBacksOff() async {
        let cloud = FakeEngine(kind: .cloud)
        let phone = FakeEngine(kind: .whisperKit)
        let captions = pipeline(cloud: cloud, phone: phone)
        captions.cloudRecheckSeconds = 0.1
        captions.homeServerSwitchBackQuietSeconds = 0
        await captions.start(settings: cloudSettings)
        for wait in [0.1, 0.2, 0.4, 0.8] {
            #expect(await eventually { captions.phase == .listening && captions.activeEngineKind == .cloud })
            cloud.endStream(throwing: EngineUnavailability(kind: .noInternet, detail: "connection lost"))
            #expect(await eventually { captions.activeEngineKind == .whisperKit && captions.currentCloudRecheckSeconds == wait })
        }

        #expect(await eventually { captions.phase == .listening && captions.activeEngineKind == .cloud })
        captions.cloudFlapWindowSeconds = 0
        cloud.endStream(throwing: EngineUnavailability(kind: .noInternet, detail: "connection lost"))
        #expect(await eventually { captions.activeEngineKind == .whisperKit && captions.currentCloudRecheckSeconds == 0.1 })
        captions.stop()
    }

    @Test("a key or credit problem is left for a person, never asked again on its own")
    func doesNotRecheckWhenAPersonMustAct() async throws {
        for kind in [EngineUnavailability.Kind.cloudKeyNeeded, .cloudOutOfCredit] {
            let cloud = FakeEngine(kind: .cloud, availability: .unavailable(kind, "test"))
            let phone = FakeEngine(kind: .whisperKit)
            let captions = pipeline(cloud: cloud, phone: phone)
            captions.cloudRecheckSeconds = 0.05
            captions.homeServerSwitchBackQuietSeconds = 0
            await captions.start(settings: cloudSettings)
            #expect(await eventually { captions.phase == .listening && captions.isCoveringForCloud }, "\(kind)")
            let before = cloud.prepareCount
            try await Task.sleep(for: .milliseconds(300))
            #expect(cloud.prepareCount == before, "\(kind)")
            #expect(captions.activeEngineKind == .whisperKit, "\(kind)")
        }
    }

    @Test("what is said while the phone's model loads to take over is kept for it, not lost")
    func wordsDuringTakeoverAreKept() async {
        let audio = FakeAudioCapturer()
        let cloud = FakeEngine(kind: .cloud)
        let phone = FakeEngine(kind: .whisperKit)
        let gate = PrepareGate()
        phone.prepareGate = gate
        let captions = CaptionPipeline(
            audio: audio,
            engineFactory: { $0.engine == .cloud ? cloud : phone },
            embedder: FakeEmbedder(),
            recovery: .disabled
        )
        await captions.start(settings: cloudSettings)
        #expect(await eventually { captions.phase == .listening && captions.activeEngineKind == .cloud })
        cloud.endStream(throwing: EngineUnavailability(kind: .noInternet, detail: "connection lost"))
        #expect(await eventually { phone.prepareCount == 1 })
        for _ in 0..<20 { audio.push([Float](repeating: 0.1, count: 256)) }
        await gate.open()
        #expect(await eventually { captions.phase == .listening && captions.activeEngineKind == .whisperKit })
        #expect(await eventually { phone.chunksSeen >= 20 })
    }
}
