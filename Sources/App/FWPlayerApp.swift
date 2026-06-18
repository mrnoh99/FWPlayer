import SwiftUI

@main
struct FWPlayerApp: App {
    @StateObject private var registry: SourceRegistry
    @State private var player: AudioPlayer
    @StateObject private var playlists: PlaylistManager
    @StateObject private var remoteServer: RemoteControlServer

    init() {
        let registry = SourceRegistry()
        let player = AudioPlayer(registry: registry)
        let playlists = PlaylistManager()
        _registry = StateObject(wrappedValue: registry)
        _player = State(initialValue: player)
        _playlists = StateObject(wrappedValue: playlists)
        _remoteServer = StateObject(wrappedValue: RemoteControlServer(
            player: player, registry: registry, playlists: playlists))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(registry)
                .environment(player)
                .environmentObject(playlists)
                .environmentObject(remoteServer)
                .onAppear {
                    registry.loadPersisted()
                    playlists.load()
                    // Make this player controllable from FWPlayerRemote on the
                    // local network.
                    remoteServer.start()
                }
        }
    }
}
