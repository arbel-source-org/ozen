import Foundation

public enum AudioPermission: Sendable, Equatable {
    case granted
    case denied
}

/// Everything the caption pipeline needs from the microphone side, as a
/// protocol so the pipeline's startup sequence can be tested end to end on
/// Linux with a fake that yields synthetic audio and fake input lists. The
/// real conformance (`AVAudioInputManager` in OzenPlatform) is the thin,
/// hardware-facing layer that CI verifies compiles and the phone verifies
/// works.
///
/// Deliberately split into `prepareSession` and `startCapture`: listing
/// microphones only needs the session, not the recording, so the mic picker
/// can be populated immediately on launch instead of after a model finishes
/// downloading — the exact gap that made the first build look broken.
@MainActor
public protocol AudioCapturing: AnyObject {
    var availableInputs: [AudioInputDescriptor] { get }
    var selectedInputUID: String? { get }
    /// Live input level in 0...1, for the meter in the mic picker so the
    /// user can see at a glance whether the mic they picked is actually
    /// hearing anything.
    var inputLevel: Float { get }
    /// Called on the main actor whenever the system reports a route
    /// change (AirPods reconnecting, a USB mic unplugged, ...).
    var onInputsChanged: (@MainActor () -> Void)? { get set }

    func requestPermission() async -> AudioPermission
    /// Configures and activates the audio session and enumerates inputs.
    /// Safe to call more than once.
    func prepareSession(preferredInputUID: String?) throws
    /// Begins delivering 16 kHz mono Float32 chunks. Requires
    /// `prepareSession` first.
    func startCapture() throws -> AsyncStream<[Float]>
    func stopCapture()
    func selectInput(uid: String) throws
    /// Asks the system for the current inputs again, even when no session
    /// has been prepared (captions never started, or failed before the
    /// microphone was set up). Must not start recording.
    func refreshInputs()
}
