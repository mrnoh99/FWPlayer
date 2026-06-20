import SwiftUI

@main
struct FWPlayerApp: App {
    @StateObject private var registry: SourceRegistry
    @StateObject private var playlists: PlaylistManager
    @StateObject private var artwork: ArtworkStore
    @StateObject private var player: AudioPlayer
    @StateObject private var remoteServer: RemoteControlServer

    init() {
        let registry = SourceRegistry()
        let playlists = PlaylistManager()
        let artwork = ArtworkStore()
        let player = AudioPlayer(registry: registry, playlists: playlists, artwork: artwork)
        _registry = StateObject(wrappedValue: registry)
        _playlists = StateObject(wrappedValue: playlists)
        _artwork = StateObject(wrappedValue: artwork)
        _player = StateObject(wrappedValue: player)
        _remoteServer = StateObject(wrappedValue: RemoteControlServer(
            player: player,
            registry: registry,
            playlists: playlists,
            artwork: artwork
        ))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(registry)
                .environmentObject(player)
                .environmentObject(playlists)
                .environmentObject(artwork)
                .environmentObject(remoteServer)
                .onAppear {
                    registry.loadPersisted()
                    playlists.load()
                    remoteServer.start()
                }
        }
    }
}
