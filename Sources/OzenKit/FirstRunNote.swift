public enum FirstRunNote: Sendable, Equatable {
    case modelDownload
    case speechPermission
    case homeComputer
    case none
}

extension TranscriptionEngineKind {
    public var firstRunNote: FirstRunNote {
        switch self {
        case .whisperKit: return .modelDownload
        case .appleSpeech: return .speechPermission
        case .homeServer: return .homeComputer
        case .cloud: return .none
        }
    }
}

extension AppSettings {
    public var audioLeavesPhone: Bool {
        switch engine {
        case .homeServer, .cloud: return true
        case .appleSpeech: return allowServerFallbackForAppleSpeech
        case .whisperKit: return false
        }
    }
}
