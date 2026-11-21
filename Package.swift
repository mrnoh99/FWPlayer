// swift-tools-version:5.9
import PackageDescription

// Test-only package: compiles the app's pure-logic sources (no UI, no iOS-only
// APIs) so they can be unit-tested with `swift test` on a Mac, without a
// simulator. The app itself is still built from FWPlayer.xcodeproj.
let package = Package(
    name: "FWPlayerCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FWPlayerCore", targets: ["FWPlayerCore"]),
    ],
    targets: [
        .target(
            name: "FWPlayerCore",
            path: "Sources/Audio",
            sources: ["AudioDecoder.swift", "DSDDoPDecoder.swift"]
        ),
        .testTarget(
            name: "FWPlayerCoreTests",
            dependencies: ["FWPlayerCore"],
            path: "Tests/FWPlayerCoreTests"
        ),
    ]
)
