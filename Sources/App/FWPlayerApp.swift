import SwiftUI

@main
struct FWPlayerApp: App {
    @StateObject private var registry: SourceRegistry
    @StateObject private var player: AudioPlayer
    @StateObject private var playlists = PlaylistManager()

    init() {
        let registry = SourceRegistry()
        _registry = StateObject(wrappedValue: registry)
        _player = StateObject(wrappedValue: AudioPlayer(registry: registry))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(registry)
                .environmentObject(player)
                .environmentObject(playlists)
                .onAppear {
                    registry.loadPersisted()
                    playlists.load()
                }
        }
    }
}
