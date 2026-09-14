import Foundation

/// Decides whether there is room on the phone for a speech model.
///
/// Models run from 76 MB to 3 GB. On a phone that is nearly full the
/// download used to start anyway, fail part of the way in, say "check your
/// internet connection" (wrong), and then be retried again and again by
/// automatic recovery, each time filling the phone to the last megabyte.
/// Checking first turns that into one clear message: free up this much
/// room, or pick a smaller model.
public enum StorageSpaceGate {
    /// Room to leave after the download. The first load compiles the model
    /// for the phone's chip and caches the result, and a phone filled to
    /// the brim starts misbehaving in other apps too.
    public static func requiredMegabytes(forDownloadOf megabytes: Int) -> Int {
        megabytes + max(megabytes / 4, 250)
    }

    /// How many more megabytes have to be freed before `megabytes` can be
    /// downloaded, or nil when there is enough room, the size isn't known,
    /// or the phone didn't say how much space is free.
    public static func shortfallMegabytes(downloadMegabytes megabytes: Int, availableBytes: Int64?) -> Int? {
        guard megabytes > 0, let availableBytes else { return nil }
        let required = Int64(requiredMegabytes(forDownloadOf: megabytes)) * bytesPerMegabyte
        guard availableBytes < required else { return nil }
        let missing = required - max(availableBytes, 0)
        return Int((missing + bytesPerMegabyte - 1) / bytesPerMegabyte)
    }

    /// Whether an error from a download or a model load means the disk is
    /// full, looking through wrapped errors (a download that can't save its
    /// file reports a URL error with the real reason underneath).
    public static func isOutOfSpace(_ error: any Error) -> Bool {
        var current: NSError? = error as NSError
        var depth = 0
        while let nsError = current, depth < 8 {
            if nsError.domain == NSCocoaErrorDomain && nsError.code == outOfSpaceCocoaCode { return true }
            if nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOSPC) { return true }
            current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return false
    }

    /// `NSFileWriteOutOfSpaceError`.
    static let outOfSpaceCocoaCode = 640
    static let bytesPerMegabyte: Int64 = 1_048_576
}
