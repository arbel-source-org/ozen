import Foundation

public enum AudioPermission: Sendable, Equatable {
    case granted
    case denied
}

@MainActor
public protocol AudioCapturing: AnyObject {
    var availableInputs: [AudioInputDescriptor] { get }
    var selectedInputUID: String? { get }
    var inputLevel: Float { get }
    var onInputsChanged: (@MainActor () -> Void)? { get set }
    var onCaptureLost: (@MainActor () -> Void)? { get set }

    func requestPermission() async -> AudioPermission
    func prepareSession(preferredInputUID: String?) async throws
    func startCapture() throws -> AsyncStream<[Float]>
    func stopCapture()
    func selectInput(uid: String) throws
    func refreshInputs()
}
