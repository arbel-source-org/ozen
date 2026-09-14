import Testing
@testable import OzenKit

@Suite("Audio stall watchdog")
struct AudioStallWatchdogTests {
    @Test("the stall window is rounded up to whole ticks")
    func ticksFromSeconds() {
        #expect(AudioStallWatchdog(stallSeconds: 6).stallTicks == 24)
        #expect(AudioStallWatchdog(stallSeconds: 0.3).stallTicks == 2)
        #expect(AudioStallWatchdog(stallSeconds: 0).stallTicks == 1)
    }

    @Test("it fires on the tick that completes the window, and only once")
    func firesOnce() {
        var watchdog = AudioStallWatchdog(stallSeconds: 0.75)
        var fired: [Bool] = []
        for _ in 0..<6 {
            fired.append(watchdog.tick(chunksReceived: 10, systemInterrupted: false))
        }
        // First tick records the count; then three quiet ticks make a stall.
        #expect(fired == [false, false, false, true, false, false])
    }

    @Test("any new chunk starts the count over")
    func newAudioResets() {
        var watchdog = AudioStallWatchdog(stallSeconds: 0.75)
        var count = 0
        for _ in 0..<20 {
            count += 1
            _ = watchdog.tick(chunksReceived: count, systemInterrupted: false)
            _ = watchdog.tick(chunksReceived: count, systemInterrupted: false)
            let fired = watchdog.tick(chunksReceived: count, systemInterrupted: false)
            #expect(fired == false)
        }
    }

    @Test("a phone call holding the audio session is not a stall, and the count restarts after it")
    func interruptionIsNotAStall() {
        var watchdog = AudioStallWatchdog(stallSeconds: 0.75)
        _ = watchdog.tick(chunksReceived: 5, systemInterrupted: false)
        _ = watchdog.tick(chunksReceived: 5, systemInterrupted: false)
        var duringCall: [Bool] = []
        for _ in 0..<40 {
            duringCall.append(watchdog.tick(chunksReceived: 5, systemInterrupted: true))
        }
        #expect(!duringCall.contains(true))
        // The window starts when the call ends: three quiet ticks after it.
        var afterCall: [Bool] = []
        for _ in 0..<4 {
            afterCall.append(watchdog.tick(chunksReceived: 5, systemInterrupted: false))
        }
        #expect(afterCall == [false, false, true, false])
    }

    @Test("reset forgets earlier quiet ticks")
    func resetForgets() {
        var watchdog = AudioStallWatchdog(stallSeconds: 0.5)
        _ = watchdog.tick(chunksReceived: 1, systemInterrupted: false)
        _ = watchdog.tick(chunksReceived: 1, systemInterrupted: false)
        watchdog.reset()
        var fired: [Bool] = []
        for _ in 0..<3 {
            fired.append(watchdog.tick(chunksReceived: 1, systemInterrupted: false))
        }
        #expect(fired == [false, false, true])
    }

    @Test("a disabled watchdog never fires")
    func disabled() {
        var watchdog = AudioStallWatchdog.disabled
        var fired = false
        for _ in 0..<1_000 {
            fired = watchdog.tick(chunksReceived: 0, systemInterrupted: false) || fired
        }
        #expect(fired == false)
    }
}
