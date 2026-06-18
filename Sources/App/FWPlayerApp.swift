import SwiftUI

@main
struct FWPlayerApp: App {
    @StateObject private var registry: SourceRegistry
    @StateObject private var playlists: PlaylistManager
    @StateObject private var player: AudioPlayer
    @StateObject private var remoteServer: RemoteControlServer

    init() {
        let registry = SourceRegistry()
        let playlists = PlaylistManager()
        let player = AudioPlayer(registry: registry, playlists: playlists)
        _registry = StateObject(wrappedValue: registry)
        _playlists = StateObject(wrappedValue: playlists)
        _player = StateObject(wrappedValue: player)
        _remoteServer = StateObject(wrappedValue: RemoteControlServer(
            player: player,
            registry: registry,
            playlists: playlists
        ))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(registry)
                .environmentObject(player)
                .environmentObject(playlists)
                .environmentObject(remoteServer)
                .onAppear {
                    registry.loadPersisted()
                    playlists.load()
                    remoteServer.start()
                }
        }
    }
}
