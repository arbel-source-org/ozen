import Foundation

public struct MicrophoneDropNotice: Sendable, Equatable {
    public private(set) var lost: AudioInputDescriptor?

    public init() {}

    public mutating func inputChanged(from previous: AudioInputDescriptor?, to current: AudioInputDescriptor?, isListening: Bool) {
        guard let current, current.portType == .builtInMic else {
            if current != nil { lost = nil }
            return
        }
        if isListening, let previous, previous.uid != current.uid, Self.placedNearTheTalker.contains(previous.portType) {
            lost = previous
        }
    }

    public mutating func dismiss() {
        lost = nil
    }

    private static let placedNearTheTalker: Set<AudioPortType> = [.wired, .usb, .remoteMic]

    public var title: String? {
        lost.map { tr("המיקרופון \u{2068}\($0.portName)\u{2069} התנתק", "\($0.portName) disconnected") }
    }

    public static var detail: String {
        tr(
            "הכתוביות ממשיכות דרך המיקרופון של הטלפון, ואולי יהיו פחות מדויקות. חברו אותו שוב כדי לחזור אליו.",
            "Captions carry on through the phone's own microphone and may be less accurate. Reconnect it to go back to it."
        )
    }
}
