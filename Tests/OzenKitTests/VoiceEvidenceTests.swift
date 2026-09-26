import Foundation
import Testing
@testable import OzenKit

@Suite("Telling a voice from household noise before Whisper sees it")
struct VoiceEvidenceTests {
    let chunk = VoiceEvidence.chunkSamples

    final class Recorder: @unchecked Sendable {
        var inputs: [[Float]] = []
        var answers: [Float?]
        init(_ answers: [Float?]) { self.answers = answers }
        func score(_ input: [Float]) -> Float? {
            inputs.append(input)
            return answers.isEmpty ? 0 : answers.removeFirst()
        }
    }

    @Test("noise only: no voice")
    func noise() {
        let recorder = Recorder([0.1, 0.2, 0.3])
        var evidence = VoiceEvidence(score: recorder.score)
        evidence.append([Float](repeating: 0.01, count: chunk * 3))
        #expect(evidence.hasVoice(inFirst: chunk * 3) == false)
    }

    @Test("one voiced chunk is enough, even at the edge of the line")
    func oneVoicedChunk() {
        let recorder = Recorder([0.1, 0.1, 0.9])
        var evidence = VoiceEvidence(score: recorder.score)
        evidence.append([Float](repeating: 0.01, count: chunk * 3))
        #expect(evidence.hasVoice(inFirst: chunk * 3) == true)
        #expect(evidence.hasVoice(inFirst: chunk * 2 + 1) == true)
        #expect(evidence.hasVoice(inFirst: chunk * 2) == false)
    }

    @Test("nothing scored yet, or a failed scorer, never removes a line")
    func unknown() {
        var fresh = VoiceEvidence(score: Recorder([0.1]).score)
        fresh.append([Float](repeating: 0.01, count: chunk - 1))
        #expect(fresh.hasVoice(inFirst: chunk - 1) == nil)

        var broken = VoiceEvidence(score: Recorder([0.1, nil]).score)
        broken.append([Float](repeating: 0.01, count: chunk * 3))
        #expect(broken.hasVoice(inFirst: chunk * 3) == nil)
    }

    @Test("one failed score leaves only its own chunk unknown; the gate works again after it")
    func recoversAfterAFailure() {
        var evidence = VoiceEvidence(score: Recorder([nil, 0.1, 0.1]).score)
        evidence.append([Float](repeating: 0.01, count: chunk * 3))
        #expect(evidence.hasVoice(inFirst: chunk * 3) == nil)
        evidence.drop(prefix: chunk)
        #expect(evidence.hasVoice(inFirst: chunk * 2) == false)
    }

    @Test("a quiet voice is brought up to a common level before it is scored, and only a sure score counts")
    func quietVoiceIsLevelled() {
        let recorder = Recorder([0.85, 0.95])
        var evidence = VoiceEvidence(score: recorder.score)
        evidence.append([Float](repeating: 0.01, count: chunk * 2))
        let loudest = recorder.inputs[0].map(abs).max() ?? 0
        #expect(loudest > 0.45 && loudest <= 0.5)
        #expect(evidence.hasVoice(inFirst: chunk) == false)
        #expect(evidence.hasVoice(inFirst: chunk * 2) == true)
    }

    @Test("follows the caller dropping the start of its buffer")
    func drop() {
        let recorder = Recorder([0.9, 0.1, 0.1])
        var evidence = VoiceEvidence(score: recorder.score)
        evidence.append([Float](repeating: 0.01, count: chunk * 3))
        #expect(evidence.hasVoice(inFirst: chunk) == true)
        evidence.drop(prefix: chunk)
        #expect(evidence.hasVoice(inFirst: chunk * 2) == false)
    }

    @Test("the scorer sees each chunk after the end of the one before, in arrival pieces of any size")
    func context() {
        let recorder = Recorder([])
        var evidence = VoiceEvidence(score: recorder.score)
        let samples = (0..<(chunk * 2)).map { Float($0) }
        evidence.append(Array(samples[0..<1000]))
        evidence.append(Array(samples[1000...]))
        #expect(recorder.inputs.count == 2)
        #expect(recorder.inputs[0].count == VoiceEvidence.contextSamples + chunk)
        #expect(recorder.inputs[0].prefix(VoiceEvidence.contextSamples).allSatisfy { $0 == 0 })
        #expect(Array(recorder.inputs[1].prefix(VoiceEvidence.contextSamples)) == Array(samples[(chunk - VoiceEvidence.contextSamples)..<chunk]))
        #expect(Array(recorder.inputs[1].suffix(chunk)) == Array(samples[chunk...]))
    }
}
