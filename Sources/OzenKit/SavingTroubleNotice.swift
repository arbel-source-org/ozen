import Foundation

/// Whether the caption screen should say that saving is failing.
///
/// A phone with no free space keeps captioning, so nothing looks wrong,
/// while every autosave of the conversation and every settings change
/// quietly fails to reach the disk. The History screen and Diagnostics
/// already say so, but only to someone who opens them. This puts it where
/// she is looking, once: dismissed, it stays away until saving works again
/// and then fails again.
public struct SavingTroubleNotice: Sendable, Equatable {
    public private(set) var isFailing = false
    private var isDismissed = false

    public init() {}

    public var shouldShow: Bool { isFailing && !isDismissed }

    /// `settingsFailed` and `historyFailed`: whether the most recent save of
    /// each failed. A history failure should only count while history is
    /// being saved at all.
    public mutating func update(settingsFailed: Bool, historyFailed: Bool) {
        let failing = settingsFailed || historyFailed
        if !failing { isDismissed = false }
        isFailing = failing
    }

    public mutating func dismiss() {
        isDismissed = true
    }

    public static let title = "השמירה בטלפון נכשלה"
    public static let detail = "כנראה שהטלפון מלא. שיחות והגדרות חדשות לא יישמרו עד שיתפנה מקום: הגדרות ← כללי ← אחסון iPhone."
}
