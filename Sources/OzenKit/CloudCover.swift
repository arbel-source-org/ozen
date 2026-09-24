public enum CloudCover {
    public static func phoneSettings(replacing settings: AppSettings, after failure: PipelineFailure) -> AppSettings? {
        guard settings.engine == .cloud, let kind = failure.engineUnavailability?.kind else { return nil }
        switch kind {
        case .cloudKeyNeeded, .cloudOutOfCredit, .noInternet:
            var onPhone = settings
            onPhone.engine = .whisperKit
            return onPhone
        default:
            return nil
        }
    }
}
