import Testing
@testable import OzenKit

struct BackupModelTests {
    private func status(
        engine: TranscriptionEngineKind = .homeServer,
        installed: Bool = false,
        downloading: Double? = nil,
        failed: Bool = false,
        shortfall: Int? = nil,
        network: NetworkConditions? = .wifi,
        allowCellular: Bool = false
    ) -> BackupModelStatus {
        BackupModel.status(
            engine: engine, installed: installed, sizeMegabytes: 626, downloading: downloading, failed: failed,
            shortfallMegabytes: shortfall, network: network, allowCellular: allowCellular
        )
    }

    @Test("only a computer or cloud engine needs a backup; one already on the phone is ready")
    func needAndReady() {
        #expect(status(engine: .whisperKit) == .notNeeded)
        #expect(status(engine: .appleSpeech) == .notNeeded)
        #expect(status(engine: .cloud) == .missing(megabytes: 626))
        #expect(status(installed: true) == .ready)
        #expect(status(installed: true, network: .offline) == .ready)
    }

    @Test("a download in progress shows its progress, before any network or room problem")
    func downloading() {
        #expect(status(downloading: 0.4, network: .cellular) == .downloading(fraction: 0.4))
        #expect(status(downloading: 0.4, shortfall: 100) == .downloading(fraction: 0.4))
    }

    @Test("a missing backup waits for Wi-Fi like any model download, says when the phone is full, and can be retried after a failure")
    func blockers() {
        #expect(status(network: .cellular) == .waitingForWiFi)
        #expect(status(network: .cellular, allowCellular: true) == .missing(megabytes: 626))
        #expect(status(network: .offline) == .offline)
        #expect(status(shortfall: 300) == .notEnoughRoom(megabytes: 300))
        #expect(status(failed: true) == .failed)
        #expect(BackupModel.canStart(status()))
        #expect(BackupModel.canStart(status(failed: true)))
        #expect(!BackupModel.canStart(status(network: .cellular)))
        #expect(!BackupModel.canStart(status(downloading: 0.1)))
        #expect(!BackupModel.canStart(status(installed: true)))
    }

    @Test("a computer that can't be reached offers the backup only while one could still be fetched")
    func offer() {
        #expect(BackupModel.shouldOffer(after: .homeServerUnreachable, status: .missing(megabytes: 626)))
        #expect(BackupModel.shouldOffer(after: .homeServerUnreachable, status: .failed))
        #expect(BackupModel.shouldOffer(after: .homeServerUnreachable, status: .waitingForWiFi))
        #expect(!BackupModel.shouldOffer(after: .homeServerUnreachable, status: .ready))
        #expect(!BackupModel.shouldOffer(after: .homeServerUnreachable, status: .downloading(fraction: 0.2)))
        #expect(!BackupModel.shouldOffer(after: .homeServerUnreachable, status: .offline))
        #expect(!BackupModel.shouldOffer(after: .homeServerRejected, status: .missing(megabytes: 626)))
        #expect(!BackupModel.shouldOffer(after: nil, status: .missing(megabytes: 626)))
    }
}
