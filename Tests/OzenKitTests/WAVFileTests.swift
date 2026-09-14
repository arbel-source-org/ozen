import Foundation
import Testing
@testable import OzenKit

@Suite("WAVFile")
struct WAVFileTests {
    private func uint32(_ data: Data, at offset: Int) -> UInt32 {
        data.subdata(in: offset..<(offset + 4)).withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
    }

    private func int16(_ data: Data, at offset: Int) -> Int16 {
        data.subdata(in: offset..<(offset + 2)).withUnsafeBytes { Int16(littleEndian: $0.loadUnaligned(as: Int16.self)) }
    }

    @Test("a mono 16-bit header that says how much audio follows")
    func header() {
        let wav = WAVFile.pcm16([0, 0.5, -0.5], sampleRate: 16_000)
        #expect(wav.count == 44 + 6)
        #expect(String(decoding: wav[0..<4], as: UTF8.self) == "RIFF")
        #expect(uint32(wav, at: 4) == 36 + 6)
        #expect(String(decoding: wav[8..<16], as: UTF8.self) == "WAVEfmt ")
        #expect(int16(wav, at: 22) == 1)
        #expect(uint32(wav, at: 24) == 16_000)
        #expect(uint32(wav, at: 28) == 32_000)
        #expect(int16(wav, at: 34) == 16)
        #expect(String(decoding: wav[36..<40], as: UTF8.self) == "data")
        #expect(uint32(wav, at: 40) == 6)
    }

    @Test("samples become 16-bit values, too loud clipped and damaged ones silent")
    func samples() {
        let wav = WAVFile.pcm16([1, -1, 0.5, 3, -3, .nan, .infinity], sampleRate: 16_000)
        let values = (0..<7).map { int16(wav, at: 44 + $0 * 2) }
        #expect(values == [32_767, -32_767, 16_384, 32_767, -32_767, 0, 0])
    }

    @Test("no audio is still a readable file")
    func empty() {
        let wav = WAVFile.pcm16([], sampleRate: 16_000)
        #expect(wav.count == 44)
        #expect(uint32(wav, at: 40) == 0)
    }
}
