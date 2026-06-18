import SwiftUI

@main
struct FWPlayerApp: App {
    @StateObject private var registry: SourceRegistry
    @StateObject private var playlists: PlaylistManager
    @StateObject private var player: AudioPlayer

    init() {
        let registry = SourceRegistry()
        let playlists = PlaylistManager()
        _registry = StateObject(wrappedValue: registry)
        _playlists = StateObject(wrappedValue: playlists)
        _player = StateObject(wrappedValue: AudioPlayer(registry: registry, playlists: playlists))
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
