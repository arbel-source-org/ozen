import Foundation
import Speech
import AVFoundation
import OzenKit

/// Wraps `SFSpeechRecognizer` locked to on-device recognition. Deliberately
/// refuses to silently fall back to Apple's server-based recognizer when
/// on-device isn't available for the requested language — doing that
/// quietly would break the on-device-only requirement (privacy, works with
/// no signal, lowest latency) without anyone noticing. `checkAvailability`
/// is what Settings calls to decide whether to even offer this engine as
/// an option for the current language/device.
public final class AppleSpeechEngine: TranscriptionEngine, @unchecked Sendable {
    public let kind: TranscriptionEngineKind = .appleSpeech

    public init() {}

    public func checkAvailability(languageCode: String) async -> EngineAvailability {
        let locale = Locale(identifier: Self.localeIdentifier(for: languageCode))
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            return .unavailable(reason: "No speech recognizer installed for \(locale.identifier)")
        }
        guard recognizer.supportsOnDeviceRecognition else {
            return .unavailable(reason: "On-device recognition isn't available for \(locale.identifier) on this device/OS version")
        }
        guard recognizer.isAvailable else {
            return .unavailable(reason: "Recognizer is temporarily unavailable")
        }
        let authStatus = await Self.requestAuthorization()
        guard authStatus == .authorized else {
            return .unavailable(reason: "Speech recognition permission not granted")
        }
        return .available
    }

    public func stream(
        languageCode: String,
        audio: AsyncStream<[Float]>
    ) -> AsyncThrowingStream<TranscriptToken, Error> {
        AsyncThrowingStream { continuation in
            let locale = Locale(identifier: Self.localeIdentifier(for: languageCode))
            guard let recognizer = SFSpeechRecognizer(locale: locale) else {
                continuation.finish(throwing: EngineError.recognizerUnavailable)
                return
            }

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.requiresOnDeviceRecognition = true

            let utteranceID = UUID()
            // `SFSpeechRecognitionTask.cancel()` is documented as safe to
            // call from any thread, but the type itself isn't marked
            // Sendable, so capturing it in this `@Sendable` closure needs
            // an explicit, deliberate opt-out rather than a silent one.
            nonisolated(unsafe) let task = recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    continuation.finish(throwing: error)
                    return
                }
                guard let result else { return }
                continuation.yield(TranscriptToken(
                    utteranceID: utteranceID,
                    text: result.bestTranscription.formattedString,
                    isFinal: result.isFinal,
                    timestamp: Date().timeIntervalSince1970
                ))
                if result.isFinal {
                    continuation.finish()
                }
            }

            let feedTask = Task {
                for await chunk in audio {
                    if let buffer = Self.pcmBuffer(from: chunk) {
                        request.append(buffer)
                    }
                }
                request.endAudio()
            }

            continuation.onTermination = { _ in
                task.cancel()
                feedTask.cancel()
            }
        }
    }

    private static func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    static func localeIdentifier(for languageCode: String) -> String {
        languageCode == "he" ? "he-IL" : languageCode
    }

    private static func pcmBuffer(from samples: [Float]) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channelData = buffer.floatChannelData
        else {
            return nil
        }
        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBufferPointer { pointer in
            guard let base = pointer.baseAddress else { return }
            channelData[0].update(from: base, count: samples.count)
        }
        return buffer
    }

    enum EngineError: Error {
        case recognizerUnavailable
    }
}
