import Foundation
import Observation
import OzenKit
import OzenPlatform

/// Orchestrates the whole live pipeline: audio in, split to both the
/// transcription engine and the speaker embedder, tokens stabilized into
/// displayable segments, embeddings clustered into speakers. Everything
/// this type depends on is a protocol from OzenKit/OzenPlatform, so the
/// pieces with real logic (`CaptionStabilizer`, `EmbeddingClusterer`,
/// `AudioRoutePolicy`) stay unit-testable on their own — this class is
/// deliberately just wiring.
@MainActor
@Observable
public final class LiveCaptionViewModel {
    public private(set) var segments: [TranscriptSegment] = []
    public private(set) var availableInputs: [AudioInputDescriptor] = []
    public private(set) var selectedInputUID: String?
    public private(set) var isListening = false
    public private(set) var engineAvailability: EngineAvailability = .unavailable(reason: "Not checked yet")

    public var settings: AppSettings

    private let settingsStore: SettingsStore
    private let audioManager = AVAudioInputManager()
    private let embedder: SpeakerEmbedding = MFCCSpeakerEmbedder()
    private var clusterer = EmbeddingClusterer()
    private var stabilizer = CaptionStabilizer()
    private var streamTask: Task<Void, Never>?
    private var utteranceClusterAssignments: [UUID: Int] = [:]

    public init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
        self.settings = settingsStore.load()
        for profile in settings.speakerProfiles {
            _ = clusterer.enroll(name: profile.name, embedding: profile.embedding)
        }
    }

    public func start() async {
        guard !isListening else { return }

        let engine = makeEngine()
        engineAvailability = await engine.checkAvailability(languageCode: settings.languageCode)
        guard case .available = engineAvailability else { return }

        do {
            try audioManager.start(preferredInputUID: settings.preferredInputUID)
        } catch {
            engineAvailability = .unavailable(reason: "Couldn't start audio: \(error.localizedDescription)")
            return
        }

        availableInputs = audioManager.availableInputs
        selectedInputUID = audioManager.selectedInputUID
        isListening = true

        let (engineAudio, embedderAudio) = Self.tee(audioManager.audioChunks())
        let tokenStream = engine.stream(languageCode: settings.languageCode, audio: engineAudio)

        streamTask = Task { [weak self] in
            guard let self else { return }
            async let embedding: Void = self.consumeEmbeddings(embedderAudio)
            do {
                for try await token in tokenStream {
                    self.handle(token: token)
                }
            } catch {
                self.engineAvailability = .unavailable(reason: "Transcription stopped: \(error.localizedDescription)")
            }
            _ = await embedding
        }
    }

    public func stop() {
        streamTask?.cancel()
        streamTask = nil
        audioManager.stop()
        isListening = false
    }

    public func selectInput(uid: String) {
        do {
            try audioManager.selectInput(uid: uid)
            selectedInputUID = audioManager.selectedInputUID
            settings.preferredInputUID = uid
            persistSettings()
        } catch {
            // Deliberately swallow selection failures rather than crash a
            // live conversation over a mic switch — the previous input
            // stays active until the user tries again.
        }
    }

    public func setEngine(_ kind: TranscriptionEngineKind) {
        settings.engine = kind
        persistSettings()
    }

    /// Records a fresh voice profile from a ~30-60s enrollment recording.
    public func enroll(name: String, samples: [Float]) {
        guard let embedding = embedder.embed(samples: samples, sampleRate: 16_000) else { return }
        _ = clusterer.enroll(name: name, embedding: embedding)
        settings.speakerProfiles.append(SpeakerProfile(name: name, embedding: embedding))
        persistSettings()
    }

    /// The "who is this?" flow: tag an already-inferred cluster by name
    /// using one of its own segments, after the fact.
    public func nameSpeaker(of segment: TranscriptSegment, name: String) {
        guard let clusterID = segment.speakerClusterID else { return }
        clusterer.nameCluster(id: clusterID, name: name)
        if let embedding = clusterer.clusters.first(where: { $0.id == clusterID })?.centroid {
            settings.speakerProfiles.append(SpeakerProfile(name: name, embedding: embedding))
            persistSettings()
        }
    }

    public func displayName(for segment: TranscriptSegment) -> String {
        clusterer.displayName(forClusterID: segment.speakerClusterID)
    }

    private func handle(token: TranscriptToken) {
        var enriched = token
        enriched.speakerClusterID = utteranceClusterAssignments[token.utteranceID]
        let segment = stabilizer.ingest(enriched)
        upsert(segment)
    }

    private func consumeEmbeddings(_ audio: AsyncStream<[Float]>) async {
        var buffer: [Float] = []
        let windowSamples = Int(1.5 * 16_000)
        for await chunk in audio {
            buffer.append(contentsOf: chunk)
            guard buffer.count >= windowSamples else { continue }
            defer { buffer.removeAll(keepingCapacity: true) }

            guard let embedding = embedder.embed(samples: buffer, sampleRate: 16_000) else { continue }
            let clusterID = clusterer.assign(embedding: embedding)
            guard let currentUtteranceID = stabilizer.segments.last(where: { !$0.isCommitted })?.id else { continue }
            utteranceClusterAssignments[currentUtteranceID] = clusterID
            if let index = segments.firstIndex(where: { $0.id == currentUtteranceID }) {
                segments[index].speakerClusterID = clusterID
            }
        }
    }

    private func upsert(_ segment: TranscriptSegment) {
        if let index = segments.firstIndex(where: { $0.id == segment.id }) {
            segments[index] = segment
        } else {
            segments.append(segment)
        }
    }

    private func makeEngine() -> any TranscriptionEngine {
        switch settings.engine {
        case .whisperKit: return WhisperKitEngine()
        case .appleSpeech: return AppleSpeechEngine()
        }
    }

    private func persistSettings() {
        try? settingsStore.save(settings)
    }

    /// Splits one audio stream into two independent consumers — the
    /// transcription engine and the speaker embedder both need every
    /// sample — without either blocking or starving the other.
    private static func tee(_ source: AsyncStream<[Float]>) -> (AsyncStream<[Float]>, AsyncStream<[Float]>) {
        var continuationA: AsyncStream<[Float]>.Continuation!
        var continuationB: AsyncStream<[Float]>.Continuation!
        let streamA = AsyncStream<[Float]> { continuationA = $0 }
        let streamB = AsyncStream<[Float]> { continuationB = $0 }

        Task {
            for await chunk in source {
                continuationA.yield(chunk)
                continuationB.yield(chunk)
            }
            continuationA.finish()
            continuationB.finish()
        }
        return (streamA, streamB)
    }
}
