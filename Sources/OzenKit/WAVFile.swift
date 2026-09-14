import Foundation

public enum WAVFile {
    public static func pcm16(_ samples: [Float], sampleRate: Int) -> Data {
        let pcm = samples.map { sample -> Int16 in
            let clamped = sample.isFinite ? min(max(sample, -1), 1) : 0
            return Int16((clamped * Float(Int16.max)).rounded()).littleEndian
        }
        let dataBytes = UInt32(pcm.count * 2)
        var data = Data(capacity: 44 + pcm.count * 2)
        data.append(contentsOf: Array("RIFF".utf8))
        append(&data, UInt32(36) + dataBytes)
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(&data, UInt32(16))
        append(&data, UInt16(1))
        append(&data, UInt16(1))
        append(&data, UInt32(sampleRate))
        append(&data, UInt32(sampleRate * 2))
        append(&data, UInt16(2))
        append(&data, UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        append(&data, dataBytes)
        pcm.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }

    private static func append<T: FixedWidthInteger>(_ data: inout Data, _ value: T) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
}
