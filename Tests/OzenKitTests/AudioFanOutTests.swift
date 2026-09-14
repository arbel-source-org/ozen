import Testing
@testable import OzenKit

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
