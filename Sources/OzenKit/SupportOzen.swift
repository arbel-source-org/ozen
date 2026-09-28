import Foundation

public struct DonationAddress: Sendable, Hashable, Identifiable {
    public let coin: String
    public let address: String
    public let scheme: String
    public var chainSuffix = ""

    public var id: String { coin }
    public var paymentURI: String { "\(scheme):\(address)\(chainSuffix)" }
}

public enum SupportOzen {
    public static let bitcoin = DonationAddress(
        coin: "Bitcoin (BTC)",
        address: "bc1qk5aym0mch042200s2wrc366r3hsxxmgc9nu7tm",
        scheme: "bitcoin"
    )
    public static let ethereum = DonationAddress(
        coin: "Ethereum (ETH, USDC, USDT)",
        address: "0x0Ea2210fcB0BbF2C3202d9663dB762F1f51b1BBC",
        scheme: "ethereum",
        chainSuffix: "@1"
    )
    public static let monero = DonationAddress(
        coin: "Monero (XMR)",
        address: "46otohcpNKQfFi9F21ZHTcSiNVrLMw4yMS1SFM5hbDfu5LZCzLGkEZ2Vx4YD5kwK3nKUG6GjMf37z7i6sFQR2NEC1W9ubhb",
        scheme: "monero"
    )

    public static let addresses = [bitcoin, ethereum, monero]
}
