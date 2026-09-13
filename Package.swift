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
    .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0")
)
targets.append(contentsOf: [
    .target(
        name: "OzenPlatform",
        dependencies: [
            "OzenKit",
            .product(name: "WhisperKit", package: "WhisperKit"),
        ],
        swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    .testTarget(
        name: "OzenPlatformTests",
        dependencies: ["OzenPlatform"],
        swiftSettings: [.swiftLanguageMode(.v6)]
    ),
])
#endif

let package = Package(
    name: "OzenKit",
    defaultLocalization: "he",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "OzenKit", targets: ["OzenKit"])
    ],
    dependencies: dependencies,
    targets: targets
)
