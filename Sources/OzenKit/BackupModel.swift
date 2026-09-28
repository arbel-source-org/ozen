public enum BackupModelStatus: Sendable, Equatable {
    case notNeeded
    case ready
    case missing(megabytes: Int)
    case downloading(fraction: Double)
    case waitingForWiFi
    case offline
    case notEnoughRoom(megabytes: Int)
    case failed
}

public enum BackupModel {
    public static func status(
        engine: TranscriptionEngineKind,
        installed: Bool,
        sizeMegabytes: Int,
        downloading: Double?,
        failed: Bool,
        shortfallMegabytes: Int?,
        network: NetworkConditions?,
        allowCellular: Bool
    ) -> BackupModelStatus {
        guard engine == .homeServer || engine == .cloud else { return .notNeeded }
        if installed { return .ready }
        if let downloading { return .downloading(fraction: downloading) }
        if let shortfallMegabytes { return .notEnoughRoom(megabytes: shortfallMegabytes) }
        switch ModelDownloadGate.decide(network: network, allowCellular: allowCellular) {
        case .offline: return .offline
        case .waitForWiFi: return .waitingForWiFi
        case .proceed: return failed ? .failed : .missing(megabytes: sizeMegabytes)
        }
    }

    public static func canStart(_ status: BackupModelStatus) -> Bool {
        switch status {
        case .missing, .failed: return true
        default: return false
        }
    }
}
