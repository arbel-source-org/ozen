import Testing
@testable import OzenKit
import Foundation

@Suite("AudioFanOut")
struct AudioFanOutTests {
    @Test("every output receives every chunk, in order, independently")
    func allOutputsGetEverything() async {
        let (source, continuation) = AsyncStream<[Float]>.makeStream()
        let fan = AudioFanOut(source: source, count: 3)

        continuation.yield([1])
        continuation.yield([2, 2])
        continuation.yield([3, 3, 3])
        continuation.finish()

        for output in fan.outputs {
            var received: [[Float]] = []
            for await chunk in output {
                received.append(chunk)
            }
            #expect(received == [[1], [2, 2], [3, 3, 3]])
        }
    }

    @Test("a glitched sample, NaN or infinite, reaches every output as silence; the rest of the chunk is untouched")
    func glitchedSamplesBecomeSilence() async {
        let (source, continuation) = AsyncStream<[Float]>.makeStream()
        let glitches = GlitchCount()
        let fan = AudioFanOut(source: source, count: 2) { glitches.add() }

        continuation.yield([0.5, .nan, -0.25])
        continuation.yield([.infinity, 0.125, -.infinity])
        continuation.yield([0.75])
        continuation.finish()

        for output in fan.outputs {
            var received: [[Float]] = []
            for await chunk in output {
                received.append(chunk)
            }
            #expect(received == [[0.5, 0, -0.25], [0, 0.125, 0], [0.75]])
        }
        #expect(glitches.value == 2)
    }

    final class GlitchCount: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.withLock { count } }
        func add() { lock.withLock { count += 1 } }
    }

    @Test("a slow consumer does not lose chunks while the fast one races ahead")
    func slowConsumerKeepsEverything() async {
        let (source, continuation) = AsyncStream<[Float]>.makeStream()
        let fan = AudioFanOut(source: source, count: 2)
        for i in 0..<50 {
            continuation.yield([Float(i)])
        }
        continuation.finish()

        var fastCount = 0
        for await _ in fan.outputs[0] { fastCount += 1 }
        #expect(fastCount == 50)

        var slowSum: Float = 0
        for await chunk in fan.outputs[1] {
            try? await Task.sleep(for: .microseconds(50))
            slowSum += chunk[0]
        }
        #expect(slowSum == Float((0..<50).reduce(0, +)))
    }

    @Test("an output nobody reads keeps only the newest audio, so it can't grow without end")
    func abandonedOutputIsBounded() async {
        let (source, continuation) = AsyncStream<[Float]>.makeStream()
        let fan = AudioFanOut(source: source, count: 2, bufferLimit: 10)
        for i in 0..<25 {
            continuation.yield([Float(i)])
        }
        continuation.finish()

        // Draining the first output waits for every chunk to have been
        // handed to both.
        for await _ in fan.outputs[0] {}

        var abandoned: [Float] = []
        for await chunk in fan.outputs[1] { abandoned.append(chunk[0]) }
        #expect(abandoned == (15..<25).map(Float.init))
    }

    @Test("a count below one still yields a single usable output")
    func minimumOneOutput() {
        let (source, _) = AsyncStream<[Float]>.makeStream()
        #expect(AudioFanOut(source: source, count: 0).outputs.count == 1)
    }
}
