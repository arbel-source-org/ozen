import Foundation

/// The broad category of an audio input, used only to label it sensibly in
/// the picker UI (e.g. showing a Bluetooth icon) — selection logic itself
/// doesn't care which kind is picked.
public enum AudioPortType: String, Sendable, Equatable, Codable {
    case builtInMic
    case bluetooth
    case wired
    case usb
    case hearingAid
    case other
}

/// A microphone Ozen could record from, described independently of
/// `AVAudioSession` so the selection logic below can be unit-tested with
/// plain fake values instead of a real audio session.
public struct AudioInputDescriptor: Sendable, Equatable, Identifiable, Codable {
    public let uid: String
    public let portName: String
    public let portType: AudioPortType

    public var id: String { uid }

    public init(uid: String, portName: String, portType: AudioPortType) {
        self.uid = uid
        self.portName = portName
        self.portType = portType
    }
}

/// Decides which input Ozen should actually record from, independent of
/// any real hardware. This exists specifically because "these apps don't
/// let you pick, and it's inconsistent" was the concrete original
/// complaint (a USB-C lavalier mic didn't work; AirPods worked but
/// inconsistently) — so the selection rule is written down as one small,
/// fully testable function rather than left implicit inside a route-change
/// notification handler.
public enum AudioRoutePolicy {
    /// - Parameters:
    ///   - available: inputs currently reported by the system.
    ///   - preferredUID: the input the user explicitly chose, if any
    ///     (persisted in `AppSettings`).
    ///   - currentUID: whatever the system currently has active, if known.
    /// - Returns: the UID Ozen should select, or nil if nothing is
    ///   available at all.
    ///
    /// Preference order: the user's explicit choice wins whenever it's
    /// actually present (so a preferred external mic reconnecting, e.g.
    /// AirPods coming back in range, is picked back up automatically);
    /// otherwise stick with whatever's already active rather than
    /// switching for no reason, unless that is a Bluetooth headset nobody
    /// chose; otherwise fall back to an available input so there's always
    /// *something* selected instead of silently recording nothing.
    ///
    /// iOS moves recording to a Bluetooth headset the moment one connects.
    /// Its microphone is a narrow-band phone-call one sitting on the
    /// listener's own ear, far from whoever is talking, and captions from
    /// it are far worse than from the phone on the table. A headset is
    /// only recorded from when it was picked, or when nothing else is here.
    public static func resolveSelection(
        available: [AudioInputDescriptor],
        preferredUID: String?,
        currentUID: String?
    ) -> String? {
        if let preferredUID, available.contains(where: { $0.uid == preferredUID }) {
            return preferredUID
        }
        let current = currentUID.flatMap { uid in available.first { $0.uid == uid } }
        if let current, current.portType != .bluetooth {
            return current.uid
        }
        let fallback = available.first { $0.portType == .builtInMic }
            ?? available.first { $0.portType != .bluetooth }
        return fallback?.uid ?? current?.uid ?? available.first?.uid
    }
}
