// swift-tools-version: 6.0
import PackageDescription

// OzenKit is the platform-independent core: pure Swift logic with no
// Apple-only imports, so it builds and tests on Linux (this machine has no
// Mac) as well as on macOS/iOS CI. OzenPlatform wraps the Apple-only pieces
// (WhisperKit, Speech, AVFoundation, Accelerate) behind the protocols
// OzenKit defines, and only exists at all when the manifest is evaluated on
// a Darwin platform — on Linux, `canImport(Darwin)` is false, so these
// targets and the WhisperKit dependency are never declared, and `swift
// build` / `swift test` here only ever touches the portable core.

var dependencies: [Package.Dependency] = []
var products: [Product] = [
    .library(name: "OzenKit", targets: ["OzenKit"])
]

var targets: [Target] = [
    .target(
        name: "OzenKit",
        swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    .testTarget(
        name: "OzenKitTests",
        dependencies: ["OzenKit"],
        swiftSettings: [.swiftLanguageMode(.v6)]
    ),
]

#if canImport(Darwin)
dependencies.append(
    // WhisperKit graduated into the Argmax open-source SDK at 1.0. 1.1 fixes
    // empty transcriptions whenever promptTokens are set, which is every
    // pass once the names list has an entry.
    .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.1.0")
)
products.append(.library(name: "OzenPlatform", targets: ["OzenPlatform"]))
targets.append(contentsOf: [
    .target(
        name: "OzenPlatform",
        dependencies: [
            "OzenKit",
            .product(name: "WhisperKit", package: "argmax-oss-swift"),
        ],
        resources: [.copy("CAMPlusPlus.mlpackage"), .copy("SileroVAD.mlpackage")],
        swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    .testTarget(
        name: "OzenPlatformTests",
        dependencies: ["OzenPlatform"],
        resources: [.copy("Fixtures")],
        swiftSettings: [.swiftLanguageMode(.v6)]
    ),
])
#endif

let package = Package(
    name: "OzenKit",
    defaultLocalization: "he",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: products,
    dependencies: dependencies,
    targets: targets
)
