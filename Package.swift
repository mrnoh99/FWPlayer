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
        // C DST decoder (SACD Ripper, GPL v2 — see Sources/DST/NOTICE.txt). In the
        // app it is compiled into the app target and reached via the bridging header.
        .target(
            name: "CDST",
            path: "Sources/DST",
            exclude: ["NOTICE.txt"],
            publicHeadersPath: "include"
        ),
        .target(
            name: "FWPlayerCore",
            dependencies: ["CDST"],
            path: "Sources",
            sources: [
                "Audio/AudioDecoder.swift", "Audio/DSDDoPDecoder.swift", "Audio/SACDISO.swift",
                "Audio/DSDLivePlayback.swift", "Audio/ByteSource.swift", "Audio/FLACDecoder.swift",
                "Audio/PCMFileDecoder.swift", "Audio/DiagnosticsLog.swift", "Audio/LibrarySearch.swift",
                "Audio/QueueIndex.swift", "Audio/PCMDecimator.swift", "Audio/LyricsLookup.swift",
                "Audio/LRUCache.swift", "Audio/ITunesSearch.swift", "Storage/TemporaryDownloads.swift",
                // Playlists and the remote's pairing rules.
                "Models/FileItem.swift", "Models/Track.swift", "Models/Playlist.swift",
                "Storage/PlaylistStore.swift", "Sources/PlaylistManager.swift",
                "Net/RemotePairingGuard.swift",
            ]
        ),
        .testTarget(
            name: "FWPlayerCoreTests",
            dependencies: ["FWPlayerCore"],
            path: "Tests/FWPlayerCoreTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
