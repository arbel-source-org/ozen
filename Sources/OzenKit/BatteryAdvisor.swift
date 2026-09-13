import Foundation

public enum BatteryWarning: Sendable, Equatable {
    /// Worth plugging in soon.
    case low(percent: Int)
    /// The phone may switch off before the conversation ends.
    case critical(percent: Int)

    public var percent: Int {
        switch self {
        case .low(let percent), .critical(let percent): return percent
        }
    }
}

/// Decides when to tell the reader the battery is running out.
///
/// Captions keep the microphone, the model and the screen busy for hours,
/// and nobody following a conversation is watching the battery icon. So
/// the app says it once at 20% and once more at 10%. It does not repeat on
/// every percent, stays quiet while charging, and warns again after the
/// phone was charged back up and ran down again (with a margin so a level
/// flickering around the threshold doesn't nag).
public struct BatteryAdvisor: Sendable, Equatable {
    public var lowThreshold: Float
    public var criticalThreshold: Float
    /// How far above a threshold the level must climb to re-arm it.
    public var rearmMargin: Float

    private var warnedLow = false
    private var warnedCritical = false

    public init(lowThreshold: Float = 0.20, criticalThreshold: Float = 0.10, rearmMargin: Float = 0.05) {
        self.lowThreshold = lowThreshold
        self.criticalThreshold = criticalThreshold
        self.rearmMargin = rearmMargin
    }

    /// Feed every battery reading. `level` is 0...1, or nil / negative
    /// when unknown (the simulator reports -1). Returns a warning at most
    /// once per threshold per discharge.
    public mutating func update(level: Float?, isPluggedIn: Bool) -> BatteryWarning? {
        guard let level, level >= 0 else { return nil }
        if isPluggedIn {
            warnedLow = false
            warnedCritical = false
            return nil
        }
        if level > lowThreshold + rearmMargin { warnedLow = false }
        if level > criticalThreshold + rearmMargin { warnedCritical = false }

        let percent = Int((level * 100).rounded())
        if level <= criticalThreshold, !warnedCritical {
            warnedCritical = true
            // Past the low mark too: don't follow up with a stale "low".
            warnedLow = true
            return .critical(percent: percent)
        }
        if level <= lowThreshold, !warnedLow {
            warnedLow = true
            return .low(percent: percent)
        }
        return nil
    }
}
