import Foundation
import Testing
@testable import OzenKit

@Suite("Model download gate")
struct ModelDownloadGateTests {
    @Test("Wi-Fi goes ahead; cellular and Low Data Mode wait unless allowed; offline is offline")
    func decisions() {
        #expect(ModelDownloadGate.decide(network: .wifi, allowCellular: false) == .proceed)
        #expect(ModelDownloadGate.decide(network: .cellular, allowCellular: false) == .waitForWiFi)
        #expect(ModelDownloadGate.decide(network: .cellular, allowCellular: true) == .proceed)
        let lowData = NetworkConditions(isConnected: true, isConstrained: true)
        #expect(ModelDownloadGate.decide(network: lowData, allowCellular: false) == .waitForWiFi)
        #expect(ModelDownloadGate.decide(network: lowData, allowCellular: true) == .proceed)
        #expect(ModelDownloadGate.decide(network: .offline, allowCellular: true) == .offline)
    }

    @Test("before the system reports a connection, the download itself finds out")
    func unknownNetwork() {
        #expect(ModelDownloadGate.decide(network: nil, allowCellular: false) == .proceed)
    }

    @Test("waiting for Wi-Fi never retries on a timer")
    func neverOnATimer() {
        let failure = PipelineFailure(kind: .engineUnavailable, detail: "", engineUnavailability: EngineUnavailability(kind: .waitingForWiFi, detail: ""))
        #expect(AutoRecoveryPolicy.schedule(for: failure) == .never)
    }

    @Test("the cellular download setting defaults to off and survives older settings files")
    func settingDecoding() throws {
        #expect(AppSettings.default.allowCellularModelDownload == false)
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"engine":"whisperKit"}"#.utf8))
        #expect(old.allowCellularModelDownload == false)
        var settings = AppSettings.default
        settings.allowCellularModelDownload = true
        let roundTripped = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(roundTripped.allowCellularModelDownload)
    }
}
