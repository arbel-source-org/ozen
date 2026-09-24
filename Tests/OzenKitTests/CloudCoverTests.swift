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

    @Test("a passing cloud problem is retried as before, not covered")
    func passingTroubleIsNotCovered() async {
        let cloud = FakeEngine(kind: .cloud, availability: .unavailable(.temporarilyUnavailable, "test"))
        let phone = FakeEngine(kind: .whisperKit)
        let captions = pipeline(cloud: cloud, phone: phone)
        await captions.start(settings: cloudSettings)
        #expect(captions.phase.failure?.engineUnavailability?.kind == .temporarilyUnavailable)
        #expect(phone.prepareCount == 0)
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

    @Test("an engine already on the phone is never swapped")
    func onlyCloudIsCovered() {
        let failure = PipelineFailure(kind: .engineUnavailable, detail: "", engineUnavailability: EngineUnavailability(kind: .noInternet, detail: ""))
        #expect(CloudCover.phoneSettings(replacing: .default, after: failure) == nil)
    }
}
