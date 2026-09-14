/// Notices a microphone that has gone silent in the technical sense: no
/// audio arriving at all while the screen still says "listening".
///
/// A quiet room still delivers audio (a tap sends a chunk of near-silence
/// every few dozen milliseconds), so no chunks at all means the capture
/// itself died: a Bluetooth hearing aid reconnecting left the tap bound to
/// a format that no longer exists, or the engine failed to restart after a
/// phone call. Without this, captions simply stop and the reader can't
/// tell a dead microphone from a quiet room.
///
/// It counts ticks of the pipeline's own timer instead of reading a clock,
/// so a main thread that is briefly busy (and delivering neither chunks
/// nor ticks) is never mistaken for a dead microphone.
public struct AudioStallWatchdog: Sendable, Equatable {
    /// How often the pipeline calls `tick`.
    public static let tickSeconds = 0.25

    public let isEnabled: Bool
    /// Consecutive ticks without a new chunk that count as a stall.
    public let stallTicks: Int
    private var lastChunkCount: Int?
    private var quietTicks = 0

    public init(stallSeconds: Double = 6) {
        isEnabled = true
        stallTicks = max(1, Int((stallSeconds / Self.tickSeconds).rounded(.up)))
    }

    private init(disabled: Void) {
        isEnabled = false
        stallTicks = .max
    }

    public static let disabled = AudioStallWatchdog(disabled: ())

    public var stallSeconds: Double { Double(stallTicks) * Self.tickSeconds }

    /// Call once per timer tick with the running count of chunks received.
    /// Returns `true` exactly once per stall, on the tick that completes it.
    /// While the system holds the audio session (a phone call) nothing is
    /// expected to arrive, so the count starts over.
    public mutating func tick(chunksReceived: Int, systemInterrupted: Bool) -> Bool {
        guard isEnabled else { return false }
        if systemInterrupted || chunksReceived != lastChunkCount {
            lastChunkCount = chunksReceived
            quietTicks = 0
            return false
        }
        quietTicks += 1
        return quietTicks == stallTicks
    }

    /// A new capture begins; nothing that happened before counts.
    public mutating func reset() {
        lastChunkCount = nil
        quietTicks = 0
    }
}
