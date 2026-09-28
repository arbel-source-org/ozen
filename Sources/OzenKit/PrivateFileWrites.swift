import Foundation

extension Data.WritingOptions {
    public static let privateFile: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
}

var privateFileAttributes: [FileAttributeKey: Any]? {
    #if canImport(Darwin)
    return [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
    #else
    return nil
    #endif
}
