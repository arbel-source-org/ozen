import Foundation
import AVFoundation
import Observation
import OzenKit

/// Owns the real `AVAudioSession`/`AVAudioEngine` plumbing: permission,
/// enumerating inputs, reacting to route changes and interruptions, and
/// producing the rolling 16 kHz mono Float chunks both engines and the
/// speaker embedder expect. `AudioRoutePolicy` (OzenKit, unit tested) makes
/// the actual selection decision; `CaptionPipeline` (OzenKit, unit tested
/// against a fake of this protocol) decides when each step happens. This
/// type is the thin, honestly-hard-to-unit-test layer that talks to real
/// hardware.
@MainActor
@Observable
public final class AVAudioInputManager: AudioCapturing {
    public private(set) var availableInputs: [AudioInputDescriptor] = []
    public private(set) var selectedInputUID: String?
    public private(set) var inputLevel: Float = 0
    public var onInputsChanged: (@MainActor () -> Void)?
    /// `true` when the system took the session away (an incoming call),
    /// `false` when it came back and capture resumed on its own.
    public var onInterruption: (@MainActor (Bool) -> Void)?

    public enum CaptureError: Error {
        case sessionNotPrepared
        case invalidInputFormat
        case converterUnavailable
    }

    private let session = AVAudioSession.sharedInstance()
    private var engine = AVAudioEngine()
    private var preferredInputUID: String?
    private let observers = NotificationObserverBag()
    private var sessionPrepared = false
    private var activeTap: TapState?

    public init() {}

    // MARK: - AudioCapturing

    public func requestPermission() async -> AudioPermission {
        await AVAudioApplication.requestRecordPermission() ? .granted : .denied
    }

    public func prepareSession(preferredInputUID: String?) throws {
        self.preferredInputUID = preferredInputUID
        // `.playAndRecord` rather than `.record` so the type-to-speak
        // feature can play synthesized speech without tearing the session
        // down; `.measurement` turns off the system's voice processing so
        // Whisper gets the raw signal it was trained on; `.allowBluetooth`
        // is what makes an AirPods *microphone* (HFP) selectable at all.
        try session.setCategory(
            .playAndRecord,
            mode: .measurement,
            options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker]
        )
        // iOS silences vibration while an app records, and captions are
        // recording whenever an alert can happen: without this the buzz for
        // a doorbell, her name, or someone starting to talk never comes.
        // Not fatal if refused; the banners and flashes still show.
        try? session.setAllowHapticsAndSystemSoundsDuringRecording(true)
        try session.setActive(true)
        sessionPrepared = true
        refreshAvailableInputs()
        try applySelection()
        observeNotificationsIfNeeded()
    }

    public func startCapture() throws -> AsyncStream<[Float]> {
        guard sessionPrepared else { throw CaptureError.sessionNotPrepared }
        stopCapture()

        // A fresh engine per capture: after a route change the old
        // engine's input node can report a stale format, and rebuilding is
        // cheaper than reasoning about which of its states survived.
        engine = AVAudioEngine()
        let (stream, continuation) = AsyncStream<[Float]>.makeStream()
        let tap = try TapState(
            inputFormat: engine.inputNode.outputFormat(forBus: 0),
            continuation: continuation,
            onLevel: { [weak self] level in
                Task { @MainActor [weak self] in self?.inputLevel = level }
            }
        )
        activeTap = tap
        installTap(tap)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            // Nobody will read this stream: don't leave its tap installed
            // on an engine that never ran.
            stopCapture()
            throw error
        }
        return stream
    }

    public func stopCapture() {
        if engine.isRunning || activeTap != nil {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        activeTap?.finish()
        activeTap = nil
        inputLevel = 0
    }

    /// Selects a specific input by UID (from the mic picker UI), re-running
    /// the same resolution policy so an invalid/stale UID can't leave the
    /// session in a broken state.
    public func selectInput(uid: String) throws {
        preferredInputUID = uid
        try applySelection()
        confirmSelectionSoon()
    }

    /// A request that is accepted but never moves the route causes no
    /// route change, so nothing would take the check mark back off it.
    /// Look again once a Bluetooth microphone has had time to take over.
    private func confirmSelectionSoon() {
        guard sessionPrepared else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self else { return }
            let shown = self.selectedInputUID
            self.showInputInUse()
            if self.selectedInputUID != shown {
                self.onInputsChanged?()
            }
        }
    }

    // MARK: - Session plumbing

    private func installTap(_ tap: TapState) {
        // 2048 frames at 48 kHz is ~43 ms per callback: small enough to
        // feel live, large enough that the converter isn't called
        // hundreds of times a second.
        //
        // Explicitly @Sendable, so the block doesn't belong to the main
        // actor: written inside this main-actor class and handed to an
        // Objective-C API whose block type may not be marked sendable, Swift
        // 6 would add a main-actor check to it (SE-0423), and the audio
        // thread calling it would fail that check.
        engine.inputNode.installTap(onBus: 0, bufferSize: 2_048, format: tap.inputFormat) { @Sendable buffer, _ in
            tap.process(buffer)
        }
    }

    /// After the engine reconfigures itself (a route change swapped the
    /// input's native format), the old tap is bound to the old format.
    /// Rebuild the converter and re-install, keeping the same output
    /// stream so the pipeline above never notices.
    ///
    /// A Bluetooth microphone that is still connecting can report a 0 Hz
    /// format, or refuse to start, for a moment. Try again a few times
    /// before giving up; if it never settles, the pipeline's audio
    /// watchdog sees no audio arriving and restarts capture from scratch.
    private func recoverFromConfigurationChange(attempt: Int = 0) {
        guard let current = activeTap else { return }
        engine.inputNode.removeTap(onBus: 0)
        let newFormat = engine.inputNode.outputFormat(forBus: 0)
        if newFormat.sampleRate > 0, newFormat.channelCount > 0,
           let tap = try? TapState(inputFormat: newFormat, continuation: current.continuation, onLevel: current.onLevel) {
            activeTap = tap
            installTap(tap)
            engine.prepare()
            if (try? engine.start()) != nil { return }
        }
        guard attempt < Self.configurationRetryLimit else { return }
        let engineID = ObjectIdentifier(engine)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            // Capture stopped or restarted meanwhile, or another recovery
            // (the end of a call, a second route change) already got the
            // engine running: nothing to repair, and rebuilding the tap
            // now would drop the audio that just came back.
            guard let self, self.activeTap != nil, ObjectIdentifier(self.engine) == engineID, !self.engine.isRunning else { return }
            self.recoverFromConfigurationChange(attempt: attempt + 1)
        }
    }

    private static let configurationRetryLimit = 5

    /// iOS does not promise to announce the end of an interruption: after
    /// a phone call the "ended" notice can simply never come. Called when
    /// the app is back on screen while still marked interrupted. Taking
    /// the session back fails while the call still holds it, so success
    /// means the interruption is over. Returns whether it is.
    public func reclaimSessionAfterInterruption() -> Bool {
        guard sessionPrepared else { return true }
        do {
            try session.setActive(true)
        } catch {
            return false
        }
        resumeCaptureAfterInterruption()
        return true
    }

    /// Starts capture again once an interruption is over. The microphone
    /// may not be the one from before the call: a Bluetooth headset often
    /// reconnects in another mode during a call, or the phone falls back to
    /// its own microphone, and the old tap is bound to the old format.
    /// Starting the engine into that tap gives silence at best, so the tap
    /// is rebuilt for whatever the hardware reports now, with the same
    /// retries a route change gets.
    ///
    /// The call can also leave recording on another microphone than the
    /// one she chose, so the choice is asked for again first.
    private func resumeCaptureAfterInterruption() {
        guard activeTap != nil, !engine.isRunning else { return }
        if (try? applySelection()) == nil {
            reapplySelectionSoon()
        }
        recoverFromConfigurationChange()
    }

    /// The chosen microphone was listed but refused: a hearing aid or
    /// headset still finishing its connection does that for a moment. No
    /// further route change is promised once it is ready, so ask again a
    /// few times rather than record from another microphone for good.
    private func reapplySelectionSoon(attempt: Int = 0) {
        guard sessionPrepared, attempt < Self.selectionRetryLimit, let wanted = preferredInputUID else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self, self.preferredInputUID == wanted, self.inputInUse != wanted,
                  self.availableInputs.contains(where: { $0.uid == wanted })
            else { return }
            let shown = self.selectedInputUID
            if (try? self.applySelection()) == nil {
                self.reapplySelectionSoon(attempt: attempt + 1)
            }
            if self.selectedInputUID != shown {
                self.onInputsChanged?()
            }
        }
    }

    private static let selectionRetryLimit = 3

    public func refreshInputs() {
        if !sessionPrepared {
            // The input list is only meaningful for a recording category.
            // Setting the category without activating the session changes
            // nothing audible and records nothing.
            try? session.setCategory(
                .playAndRecord,
                mode: .measurement,
                options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker]
            )
        }
        refreshAvailableInputs()
        if sessionPrepared {
            showInputInUse()
        } else {
            // Nothing is recording to ask, so the policy decides; a chosen
            // microphone unplugged since gives way to one that is here,
            // instead of keeping a check mark nothing in the list carries.
            selectedInputUID = AudioRoutePolicy.resolveSelection(
                available: availableInputs,
                preferredUID: preferredInputUID,
                currentUID: selectedInputUID
            )
        }
    }

    /// Puts the selection on the input the session is really recording
    /// from. Asking for an input and being told yes doesn't mean the route
    /// moved: a Bluetooth headset still setting up its microphone can
    /// accept the request and the phone's own microphone go on recording.
    /// Route changes arrive once the route has actually settled, so after
    /// each one the picker shows the truth; the saved preference is left
    /// alone, and asked for again at the next route change.
    private func showInputInUse() {
        if let inUse = inputInUse {
            selectedInputUID = inUse
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

    /// Asks the system for the input the policy picks. `selectedInputUID`
    /// only becomes that input once the system has accepted it: a Bluetooth
    /// microphone that is listed but not ready yet can be refused, and
    /// recording then carries on from another input. Claiming the refused
    /// one anyway would put its check mark in the picker and its name in
    /// Diagnostics while a different microphone does the listening, and
    /// route changes, which retry this on their own, have no one to tell.
    private func applySelection() throws {
        let resolved = AudioRoutePolicy.resolveSelection(
            available: availableInputs,
            preferredUID: preferredInputUID,
            currentUID: selectedInputUID
        )
        guard let resolved, let port = session.availableInputs?.first(where: { $0.uid == resolved }) else {
            selectedInputUID = resolved
            return
        }
        do {
            try session.setPreferredInput(port)
            selectedInputUID = resolved
        } catch {
            selectedInputUID = inputInUse ?? availableInputs.first(where: { $0.uid == selectedInputUID })?.uid
            throw error
        }
    }

    /// The listed input the session is recording from right now, if any.
    private var inputInUse: String? {
        session.currentRoute.inputs
            .map(\.uid)
            .first { uid in availableInputs.contains { $0.uid == uid } }
    }

    private func observeNotificationsIfNeeded() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        // Observer closures capture `self` weakly, so this bag is only about
        // not leaving dead registrations behind if the manager ever goes
        // away; it lives outside the actor so its own deinit can do the
        // removal without touching isolated state.

        // `queue: .main` guarantees these run on the main thread at
        // runtime, but each closure's own type is still plain, nonisolated
        // `(Notification) -> Void` as far as the compiler is concerned, so
        // calling into this @MainActor type's methods needs an explicit
        // hop rather than an implicit one the type system can't verify.
        observers.add(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: session, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshAvailableInputs()
                if (try? self.applySelection()) == nil {
                    self.reapplySelectionSoon()
                }
                self.showInputInUse()
                self.onInputsChanged?()
            }
        })

        observers.add(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: session, queue: .main
        ) { [weak self] notification in
            let info = notification.userInfo ?? [:]
            let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt ?? 0
            let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch AVAudioSession.InterruptionType(rawValue: typeValue) {
                case .began:
                    self.onInterruption?(true)
                case .ended:
                    let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                    if options.contains(.shouldResume) || self.activeTap != nil {
                        try? self.session.setActive(true)
                        self.resumeCaptureAfterInterruption()
                    }
                    self.onInterruption?(false)
                default:
                    break
                }
            }
        })

        observers.add(center.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main
        ) { [weak self] notification in
            // Only the identity of the engine that changed crosses into
            // the main-actor hop: the notification (and the engine it
            // carries) aren't Sendable, an ObjectIdentifier is.
            let changedEngine = (notification.object as AnyObject?).map(ObjectIdentifier.init)
            Task { @MainActor [weak self] in
                guard let self, changedEngine == ObjectIdentifier(self.engine) else { return }
                self.recoverFromConfigurationChange()
            }
        })
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
        // A Roger (Phonak Roger On/Select/Table Mic) is a remote microphone
        // placed near whoever is talking, not worn on the listener's own
        // ear like the rest of this heuristic — checked first so it isn't
        // shadowed by the general "phonak" match below.
        if name.contains("roger") {
            return .remoteMic
        }
        if name.contains("hearing") || name.contains("phonak") || name.contains("oticon") {
            return .hearingAid
        }
        switch port.portType {
        case .builtInMic: return .builtInMic
        case .bluetoothHFP, .bluetoothLE, .bluetoothA2DP: return .bluetooth
        case .headsetMic, .lineIn: return .wired
        case .usbAudio: return .usb
        default: return .other
        }
    }
}

/// Holds `NotificationCenter` observer tokens and removes them when it goes
/// away. Deliberately not actor-isolated: a `@MainActor` class's `deinit`
/// can't touch its own isolated storage under Swift 6, but a plain
/// lock-free bag owned by it can clean up in its own `deinit`.
private final class NotificationObserverBag: @unchecked Sendable {
    private var tokens: [NSObjectProtocol] = []

    var isEmpty: Bool { tokens.isEmpty }

    func add(_ token: NSObjectProtocol) {
        tokens.append(token)
    }

    deinit {
        for token in tokens {
            NotificationCenter.default.removeObserver(token)
        }
    }
}

/// Everything the audio-thread tap callback touches, bundled into one
/// reference the callback can capture safely under strict concurrency.
/// The converter is owned here (not by the manager) because it's bound to
/// one specific input format and must be rebuilt when that changes.
private final class TapState: @unchecked Sendable {
    let inputFormat: AVAudioFormat
    let continuation: AsyncStream<[Float]>.Continuation
    let onLevel: @Sendable (Float) -> Void
    private let converter: AVAudioConverter
    private let targetFormat: AVAudioFormat
    private var lastLevelPost: CFAbsoluteTime = 0

    init(
        inputFormat: AVAudioFormat,
        continuation: AsyncStream<[Float]>.Continuation,
        onLevel: @escaping @Sendable (Float) -> Void
    ) throws {
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AVAudioInputManager.CaptureError.invalidInputFormat
        }
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: target)
        else {
            throw AVAudioInputManager.CaptureError.converterUnavailable
        }
        // Left alone, a converter from a stereo input to mono keeps the
        // first channel and drops the rest. Plenty of USB-C and wireless
        // lavalier receivers are stereo, and a two-transmitter one puts the
        // second person's microphone on the right channel only: that person
        // would never be captioned. Mixing keeps everyone, at the cost of a
        // few decibels for a microphone wired to one side, which the voice
        // detector's adaptive threshold takes in its stride.
        converter.downmix = true
        // The default is a middling resampler. Going from the microphone's
        // 48 kHz to Whisper's 16 kHz costs next to nothing at the best one,
        // and keeps the consonants above 4 kHz from folding back as noise.
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        self.inputFormat = inputFormat
        self.continuation = continuation
        self.onLevel = onLevel
        self.converter = converter
        self.targetFormat = target
    }

    func process(_ buffer: AVAudioPCMBuffer) {
        let ratio = targetFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        // The converter may ask for input more than once per call when it
        // resamples. Handing it the same buffer twice would duplicate
        // audio, so it gets the buffer exactly once and "no more for now"
        // after that.
        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, output.frameLength > 0, let channelData = output.floatChannelData else { return }

        let samples = Array(UnsafeBufferPointer(start: channelData[0], count: Int(output.frameLength)))
        continuation.yield(samples)

        let now = CFAbsoluteTimeGetCurrent()
        if now - lastLevelPost >= 0.05 {
            lastLevelPost = now
            onLevel(EnergyVoiceDetector.meterLevel(forRMS: EnergyVoiceDetector.rms(samples)))
        }
    }

    func finish() {
        continuation.finish()
    }
}
