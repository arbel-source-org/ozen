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
