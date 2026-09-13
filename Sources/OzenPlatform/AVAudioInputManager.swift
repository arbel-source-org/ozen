import Foundation
import AVFoundation
import OzenKit

/// Owns the real `AVAudioSession`/`AVAudioEngine` plumbing: enumerating
/// inputs, reacting to route changes, and producing the rolling 16kHz mono
/// Float chunks both `TranscriptionEngine` implementations and the speaker
/// embedder expect. `AudioRoutePolicy` (OzenKit, unit tested) makes the
/// actual selection decision — this type is the thin, honestly-hard-to-
/// unit-test layer that talks to real hardware and calls it.
@MainActor
public final class AVAudioInputManager {
    public private(set) var availableInputs: [AudioInputDescriptor] = []
    public private(set) var selectedInputUID: String?

    private let session = AVAudioSession.sharedInstance()
    private let engine = AVAudioEngine()
    private var preferredInputUID: String?
    private var routeChangeObserver: NSObjectProtocol?

    public init() {}

    public func start(preferredInputUID: String?) throws {
        self.preferredInputUID = preferredInputUID
        try session.setCategory(.record, mode: .measurement, options: [.allowBluetooth, .allowBluetoothA2DP])
        try session.setActive(true)
        refreshAvailableInputs()
        try applySelection()
        observeRouteChanges()
    }

    public func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        if let routeChangeObserver {
            NotificationCenter.default.removeObserver(routeChangeObserver)
            self.routeChangeObserver = nil
        }
    }

    /// Selects a specific input by UID (from the mic picker UI), re-running
    /// the same resolution policy so an invalid/stale UID can't leave the
    /// session in a broken state.
    public func selectInput(uid: String) throws {
        preferredInputUID = uid
        try applySelection()
    }

    /// Streams rolling mono Float32 chunks at 16kHz regardless of the
    /// physical input's native sample rate/channel count.
    public func audioChunks() -> AsyncStream<[Float]> {
        AsyncStream { continuation in
            let inputNode = engine.inputNode
            let inputFormat = inputNode.outputFormat(forBus: 0)
            guard let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false
            ), let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
                continuation.finish()
                return
            }

            inputNode.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) { buffer, _ in
                let ratio = targetFormat.sampleRate / inputFormat.sampleRate
                let outputCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
                guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputCapacity) else { return }

                var conversionError: NSError?
                let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
                    inputStatus.pointee = .haveData
                    return buffer
                }
                guard status != .error, let channelData = outputBuffer.floatChannelData else { return }

                let samples = Array(UnsafeBufferPointer(start: channelData[0], count: Int(outputBuffer.frameLength)))
                continuation.yield(samples)
            }

            do {
                try engine.start()
            } catch {
                continuation.finish()
            }

            // Deliberately no `onTermination` cleanup here: `AVAudioInputNode`
            // isn't Sendable, and capturing it in this `@Sendable` closure
            // doesn't compile under strict concurrency. `stop()` already
            // removes the tap and is the documented way callers end capture
            // (paired 1:1 with `start()`), so nothing is actually lost.
        }
    }

    private func refreshAvailableInputs() {
        availableInputs = (session.availableInputs ?? []).map { port in
            AudioInputDescriptor(
                uid: port.uid,
                portName: port.portName,
                portType: Self.portType(for: port)
            )
        }
    }

    private func applySelection() throws {
        let resolved = AudioRoutePolicy.resolveSelection(
            available: availableInputs,
            preferredUID: preferredInputUID,
            currentUID: selectedInputUID
        )
        selectedInputUID = resolved
        guard let resolved, let port = session.availableInputs?.first(where: { $0.uid == resolved }) else { return }
        try session.setPreferredInput(port)
    }

    private func observeRouteChanges() {
        // `queue: .main` guarantees this runs on the main thread at
        // runtime, but the closure's own type is still plain, nonisolated
        // `(Notification) -> Void` as far as the compiler is concerned, so
        // calling into this @MainActor type's methods needs an explicit
        // hop rather than an implicit one the type system can't verify.
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshAvailableInputs()
                try? self.applySelection()
            }
        }
    }

    /// Maps a real `AVAudioSession.Port` to Ozen's own category. Note:
    /// `AVAudioSession.Port` has no dedicated hearing-aid case — MFi
    /// hearing aids surface as `.bluetoothLE`, same as some other BLE
    /// accessories. The `.hearingAid` name-based heuristic below is a best
    /// guess that genuinely needs verification against a real Made-for-
    /// iPhone hearing aid accessory; until that's tested on real hardware,
    /// treat it as informational labeling only, not a functional switch.
    static func portType(for port: AVAudioSessionPortDescription) -> AudioPortType {
        let name = port.portName.lowercased()
        if name.contains("hearing") || name.contains("roger") {
            return .hearingAid
        }
        switch port.portType {
        case .builtInMic: return .builtInMic
        case .bluetoothHFP, .bluetoothLE, .bluetoothA2DP: return .bluetooth
        case .headsetMic: return .wired
        case .usbAudio: return .usb
        default: return .other
        }
    }
}
