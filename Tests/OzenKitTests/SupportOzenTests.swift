import Testing
@testable import OzenKit

@Suite("Donation addresses")
struct SupportOzenTests {
    private static let bech32Charset = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l")

    private static func bech32Valid(_ address: String) -> Bool {
        let parts = address.split(separator: "1", maxSplits: 1)
        guard parts.count == 2 else { return false }
        var values = parts[0].unicodeScalars.map { Int($0.value) >> 5 } + [0]
        values += parts[0].unicodeScalars.map { Int($0.value) & 31 }
        for character in parts[1] {
            guard let index = bech32Charset.firstIndex(of: character) else { return false }
            values.append(index)
        }
        let generator = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3]
        var check = 1
        for value in values {
            let top = check >> 25
            check = (check & 0x1ffffff) << 5 ^ value
            for bit in 0..<5 where (top >> bit) & 1 == 1 {
                check ^= generator[bit]
            }
        }
        return check == 1
    }

    @Test("the Bitcoin address passes its own checksum")
    func bitcoinChecksum() {
        #expect(Self.bech32Valid(SupportOzen.bitcoin.address))
        #expect(SupportOzen.bitcoin.address.hasPrefix("bc1q"))
    }

    @Test("the Ethereum address is 20 bytes of hex")
    func ethereumShape() {
        let address = SupportOzen.ethereum.address
        #expect(address.hasPrefix("0x"))
        #expect(address.count == 42)
        let allHex = address.dropFirst(2).allSatisfy { $0.isHexDigit }
        #expect(allHex)
    }

    @Test("the Monero address is a 95-character standard address")
    func moneroShape() {
        let address = SupportOzen.monero.address
        let alphabet = Set("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")
        #expect(address.count == 95)
        #expect(address.hasPrefix("4"))
        let allBase58 = address.allSatisfy { alphabet.contains($0) }
        #expect(allBase58)
    }

    @Test("QR codes carry the wallet link with the exact address")
    func paymentURIs() {
        #expect(SupportOzen.bitcoin.paymentURI == "bitcoin:bc1qk5aym0mch042200s2wrc366r3hsxxmgc9nu7tm")
        #expect(SupportOzen.addresses.map(\.scheme) == ["bitcoin", "ethereum", "monero"])
        #expect(SupportOzen.ethereum.paymentURI == "ethereum:0x0Ea2210fcB0BbF2C3202d9663dB762F1f51b1BBC@1")
        #expect(Set(SupportOzen.addresses.map(\.id)).count == 3)
    }
}
