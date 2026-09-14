import Foundation

/// How much room is left on the phone.
public enum DeviceStorage {
    /// Free space for something the person asked for, in bytes. This is
    /// the figure iOS uses for "important" downloads, which counts space it
    /// can reclaim by clearing caches, so it matches what the Settings app
    /// shows rather than the stricter raw figure. Nil if it can't be read.
    public static func availableBytes() -> Int64? {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        guard let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let bytes = values.volumeAvailableCapacityForImportantUsage
        else { return nil }
        return bytes
    }
}
