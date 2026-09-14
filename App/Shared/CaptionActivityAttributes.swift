import ActivityKit
import Foundation

/// The Live Activity that puts the newest caption lines on the lock screen
/// and in the Dynamic Island. Compiled into both the app, which starts and
/// updates it, and the widget extension, which draws it.
nonisolated struct CaptionActivityAttributes: ActivityAttributes {
    nonisolated struct ContentState: Codable, Hashable, Sendable {
        nonisolated struct Line: Codable, Hashable, Sendable {
            /// The speaker's name, on the first line of their run only.
            var speaker: String?
            var text: String
            /// False while the line is still being written.
            var isFinal: Bool
        }

        /// Oldest first; empty while listening and nothing has been said.
        var lines: [Line]
        /// Why captions aren't running right now, when they aren't.
        var status: String?
        /// Larger lines, for someone who reads the captions large in the
        /// app (see `LockScreenTextSize`); the app cuts them shorter to fit.
        var large: Bool
    }
}

extension CaptionActivityAttributes.ContentState {
    enum CodingKeys: String, CodingKey {
        case lines, status, large
    }

    /// Lines sent by an older build, still on the lock screen after an
    /// update, carry no `large`; they are drawn regular rather than not at
    /// all.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            lines: try container.decode([Line].self, forKey: .lines),
            status: try container.decodeIfPresent(String.self, forKey: .status),
            large: try container.decodeIfPresent(Bool.self, forKey: .large) ?? false
        )
    }
}
