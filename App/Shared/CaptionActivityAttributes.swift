import ActivityKit
import Foundation

nonisolated struct CaptionActivityAttributes: ActivityAttributes {
    nonisolated struct ContentState: Codable, Hashable, Sendable {
        nonisolated struct Line: Codable, Hashable, Sendable {
            var speaker: String?
            var text: String
            var isFinal: Bool
            var sameSpeakerAsAbove: Bool? = nil
        }

        var lines: [Line]
        var status: String?
        var ageNote: String?
        var large: Bool
        var english: Bool = false
        var appName: String? = nil
        var listening: String? = nil
        var notUpdating: String? = nil
        var appRightToLeft: Bool? = nil
    }
}

nonisolated extension CaptionActivityAttributes.ContentState {
    enum CodingKeys: String, CodingKey {
        case lines, status, ageNote, large, english, appName, listening, notUpdating, appRightToLeft
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            lines: try container.decode([Line].self, forKey: .lines),
            status: try container.decodeIfPresent(String.self, forKey: .status),
            ageNote: try container.decodeIfPresent(String.self, forKey: .ageNote),
            large: try container.decodeIfPresent(Bool.self, forKey: .large) ?? false,
            english: try container.decodeIfPresent(Bool.self, forKey: .english) ?? false,
            appName: try container.decodeIfPresent(String.self, forKey: .appName),
            listening: try container.decodeIfPresent(String.self, forKey: .listening),
            notUpdating: try container.decodeIfPresent(String.self, forKey: .notUpdating),
            appRightToLeft: try container.decodeIfPresent(Bool.self, forKey: .appRightToLeft)
        )
    }
}
