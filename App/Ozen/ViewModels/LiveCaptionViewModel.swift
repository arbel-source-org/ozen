import Foundation
import Observation
import OzenKit
import OzenPlatform

/// What the screens talk to. Owns the persisted settings and the
/// `CaptionPipeline`, and is the one place that knows which settings
/// changes need a pipeline restart (engine, model, language, server
/// fallback) and which don't (font size, input, speaker names). All the
/// real sequencing lives in `CaptionPipeline` (OzenKit, unit tested with
/// fakes); this class is deliberately thin wiring.
@MainActor
@Observable
public final class LiveCaptionViewModel {
    public let pipeline: CaptionPipeline
    public private(set) var settings: AppSettings
    /// Set while the system has the audio session (an incoming call), so
    /// the screen can say why captions stopped instead of looking broken.
    public private(set) var isInterruptedBySystem = false

    private let settingsStore: SettingsStore
    private let audioManager: AVAudioInputManager?

    /// Production wiring: real microphone, real engines, MFCC embedder.
    public convenience init(settingsStore: SettingsStore) {
        let audio = AVAudioInputManager()
        let pipeline = CaptionPipeline(
            audio: audio,
            engineFactory: { settings in
                switch settings.engine {
                case .whisperKit:
                    return WhisperKitEngine(modelVariant: settings.whisperModelVariant)
                case .appleSpeech:
                    return AppleSpeechEngine(allowServerFallback: settings.allowServerFallbackForAppleSpeech)
                }
            },
            embedder: MFCCSpeakerEmbedder()
        )
        self.init(settingsStore: settingsStore, pipeline: pipeline, audioManager: audio)
    }

    /// Test wiring: any pipeline (typically one built on fakes).
    public init(settingsStore: SettingsStore, pipeline: CaptionPipeline, audioManager: AVAudioInputManager? = nil) {
        self.settingsStore = settingsStore
        self.pipeline = pipeline
        self.audioManager = audioManager
        self.settings = settingsStore.load()
        for profile in settings.speakerProfiles {
            pipeline.enroll(profile: profile)
        }
        audioManager?.onInterruption = { [weak self] began in
            self?.isInterruptedBySystem = began
        }
    }

    // MARK: - Passthroughs the views read constantly

    public var phase: PipelinePhase { pipeline.phase }
    public var segments: [TranscriptSegment] { pipeline.segments }
    public var availableInputs: [AudioInputDescriptor] { pipeline.availableInputs }
    public var selectedInputUID: String? { pipeline.selectedInputUID }
    public var isListening: Bool { pipeline.phase.isListening }
    public var inputLevel: Float { pipeline.inputLevel }
    public var stats: PipelineStats { pipeline.stats }

    public var selectedInput: AudioInputDescriptor? {
        availableInputs.first { $0.uid == selectedInputUID }
    }

    // MARK: - Lifecycle

    public func start() async {
        await pipeline.start(settings: settings)
    }

    public func retry() async {
        await pipeline.retry()
    }

    public func togglePause() async {
        if pipeline.phase == .paused {
            await pipeline.resume()
        } else if pipeline.phase.isListening {
            pipeline.pause()
        } else if pipeline.phase == .idle {
            await pipeline.start(settings: settings)
        }
    }

    public func clearTranscript() {
        pipeline.clearTranscript()
    }

    // MARK: - Inputs

    public func selectInput(uid: String) {
        pipeline.selectInput(uid: uid)
        settings.preferredInputUID = uid
        persist()
    }

    public func refreshInputs() {
        pipeline.refreshInputs()
    }

    // MARK: - Engine & model (restart the pipeline)

    public func setEngine(_ kind: TranscriptionEngineKind) async {
        guard settings.engine != kind else { return }
        settings.engine = kind
        persist()
        await restartIfRunning()
    }

    public func setWhisperModel(_ variant: String) async {
        guard settings.whisperModelVariant != variant else { return }
        settings.whisperModelVariant = variant
        persist()
        if settings.engine == .whisperKit {
            await restartIfRunning()
        }
    }

    public func setAllowServerFallback(_ allowed: Bool) async {
        guard settings.allowServerFallbackForAppleSpeech != allowed else { return }
        settings.allowServerFallbackForAppleSpeech = allowed
        persist()
        if settings.engine == .appleSpeech {
            await restartIfRunning()
        }
    }

    private func restartIfRunning() async {
        switch pipeline.phase {
        case .idle, .paused:
            return
        default:
            await pipeline.restart(settings: settings)
        }
    }

    // MARK: - Display & behaviour (no restart needed)

    public var display: DisplayPreferences {
        get { settings.display }
        set {
            settings.display = newValue
            persist()
        }
    }

    public var hapticOnSpeechResume: Bool {
        get { settings.hapticOnSpeechResume }
        set {
            settings.hapticOnSpeechResume = newValue
            persist()
        }
    }

    public var speakerSimilarityThreshold: Float {
        get { settings.speakerSimilarityThreshold }
        set {
            settings.speakerSimilarityThreshold = newValue
            pipeline.setSpeakerSimilarityThreshold(newValue)
            persist()
        }
    }

    // MARK: - Speakers

    /// Records `seconds` of the person talking and saves them as a named
    /// profile. Returns false if the recording was too short/quiet to get
    /// a usable voice print.
    public func enroll(name: String, seconds: Double, onProgress: @MainActor (Double) -> Void) async -> Bool {
        let samples = await pipeline.captureEnrollmentSamples(seconds: seconds, onProgress: onProgress)
        return enroll(name: name, samples: samples)
    }

    @discardableResult
    public func enroll(name: String, samples: [Float]) -> Bool {
        guard let embedding = pipeline.embedding(forEnrollmentSamples: samples) else { return false }
        let profile = SpeakerProfile(name: name, embedding: embedding)
        pipeline.enroll(profile: profile)
        settings.speakerProfiles.append(profile)
        persist()
        return true
    }

    /// The "who is this?" flow: tag an already-inferred cluster by name
    /// using one of its own segments, after the fact.
    public func nameSpeaker(of segment: TranscriptSegment, name: String) {
        guard let centroid = pipeline.nameSpeaker(of: segment, name: name) else { return }
        settings.speakerProfiles.append(SpeakerProfile(name: name, embedding: centroid))
        persist()
    }

    public func removeProfile(id: UUID) {
        settings.speakerProfiles.removeAll { $0.id == id }
        persist()
    }

    public func displayName(for segment: TranscriptSegment) -> String {
        pipeline.displayName(for: segment)
    }

    // MARK: - Persistence

    private func persist() {
        try? settingsStore.save(settings)
    }
}
