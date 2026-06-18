import Foundation
import Network
import Combine
import Observation
#if canImport(UIKit)
import UIKit
#endif

/// Hosts the FWPlayer remote-control endpoint. Advertises a Bonjour
/// `_fwplayer._tcp` service, accepts connections from FWPlayerRemote controllers,
/// pushes playback-state snapshots, and applies inbound transport commands to the
/// shared `AudioPlayer`.
///
/// The server is best-effort: if the local network is unavailable or the listener
/// fails, FWPlayer keeps working as a standalone player; remote control simply
/// stays unavailable.
@MainActor
final class RemoteControlServer: ObservableObject {
    /// Whether the listener is currently advertising and accepting connections.
    @Published private(set) var isRunning = false
    /// Number of remotes currently connected.
    @Published private(set) var connectedClients = 0

    private unowned let player: AudioPlayer
    private unowned let registry: SourceRegistry
    private unowned let playlists: PlaylistManager
    private var listener: NWListener?
    private var links: [ObjectIdentifier: RemoteLink] = [:]
    private let listenerQueue = DispatchQueue(label: "com.fwplayer.remote.listener")

    init(player: AudioPlayer, registry: SourceRegistry, playlists: PlaylistManager) {
        self.player = player
        self.registry = registry
        self.playlists = playlists
    }

    // MARK: - Lifecycle

    /// Starts advertising the service. Safe to call more than once.
    func start() {
        guard listener == nil else { return }
        do {
            let params = NWParameters.tcp
            params.includePeerToPeer = true
            let listener = try NWListener(using: params)
            listener.service = NWListener.Service(name: Self.deviceName, type: fwRemoteServiceType)

            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready: self?.isRunning = true
                    case .failed, .cancelled: self?.isRunning = false
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener.start(queue: listenerQueue)
            self.listener = listener

            // Push a fresh snapshot to all clients whenever playback changes.
            observePlayerChanges()
        } catch {
            isRunning = false
        }
    }

    /// Observes the playback state via the Observation framework and broadcasts a
    /// snapshot on every change, re-arming for the next one. Replaces the old
    /// Combine `objectWillChange` subscription now that `AudioPlayer` is
    /// `@Observable`.
    private func observePlayerChanges() {
        withObservationTracking {
            // Touch every property included in a snapshot so any of them re-fires.
            _ = player.isPlaying
            _ = player.isLoading
            _ = player.currentTime
            _ = player.duration
            _ = player.currentIndex
            _ = player.queue
            _ = player.errorMessage
            _ = player.audioFormatDescription
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.listener != nil else { return }
                self.broadcastState()
                self.observePlayerChanges()   // re-arm for the next change
            }
        }
    }

    func stop() {
        links.values.forEach { $0.cancel() }
        links.removeAll()
        connectedClients = 0
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        let link = RemoteLink(connection: connection)
        let key = ObjectIdentifier(link)
        link.onStateChange = { [weak self, weak link] state in
            guard let self, let link else { return }
            switch state {
            case .ready:
                // Send the current state immediately on connect.
                link.send(.state(self.snapshot()))
            case .failed, .cancelled:
                self.remove(key)
            default:
                break
            }
        }
        link.onMessage = { [weak self, weak link] message in
            guard let self, let link else { return }
            if case .command(let command) = message {
                self.apply(command, replyingTo: link)
            }
        }
        links[key] = link
        connectedClients = links.count
        link.start()
    }

    private func remove(_ key: ObjectIdentifier) {
        guard links.removeValue(forKey: key) != nil else { return }
        connectedClients = links.count
    }

    // MARK: - Commands

    private func apply(_ command: RemoteCommand, replyingTo link: RemoteLink) {
        switch command {
        case .requestState:
            link.send(.state(snapshot()))
            return
        case .togglePlayPause:
            player.togglePlayPause()
        case .play:
            if !player.isPlaying { player.togglePlayPause() }
        case .pause:
            if player.isPlaying { player.togglePlayPause() }
        case .next:
            player.next()
        case .previous:
            player.previous()
        case .seek(let time):
            player.seek(to: time)
        case .playIndex(let index):
            player.playQueueIndex(index)
        case .stop:
            player.stop()
        case .requestLibrary:
            link.send(.library(makeLibrary()))
            return
        case .browse(let sourceID, let path):
            sendListing(sourceID: sourceID, path: path, to: link)
            return
        case .setQueue(let tracks, let startAt):
            player.play(tracks: tracks.map(Self.track(from:)), startAt: startAt)
        case .enqueue(let tracks):
            player.enqueue(tracks.map(Self.track(from:)))
        }
        // Reflect the resulting state back to everyone promptly.
        broadcastState()
    }

    // MARK: - Library browsing

    private func makeLibrary() -> RemoteLibrary {
        let sources = registry.sources.map {
            RemoteSource(id: $0.id, displayName: $0.displayName, symbolName: $0.symbolName)
        }
        let lists = playlists.playlists.map { playlist in
            RemotePlaylist(
                id: playlist.id.uuidString,
                name: playlist.name,
                tracks: playlist.entries.map {
                    RemoteQueueTrack(sourceID: $0.sourceID, path: $0.path, title: $0.title)
                }
            )
        }
        return RemoteLibrary(sources: sources, playlists: lists)
    }

    /// Lists `path` within `sourceID` asynchronously and sends the result back.
    private func sendListing(sourceID: String, path: String, to link: RemoteLink) {
        guard let source = registry.source(for: sourceID) else {
            link.send(.listing(RemoteListing(sourceID: sourceID, path: path, items: [], error: "Source unavailable.")))
            return
        }
        Task { [weak link] in
            let listing: RemoteListing
            do {
                let items = try await source.list(path: path).compactMap { item -> RemoteFileItem? in
                    switch item.kind {
                    case .directory: return RemoteFileItem(path: item.path, name: item.name, kind: .directory, size: item.size)
                    case .audio: return RemoteFileItem(path: item.path, name: item.name, kind: .audio, size: item.size)
                    case .other: return nil
                    }
                }
                listing = RemoteListing(sourceID: sourceID, path: path, items: items, error: nil)
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                listing = RemoteListing(sourceID: sourceID, path: path, items: [], error: message)
            }
            link?.send(.listing(listing))
        }
    }

    private static func track(from queueTrack: RemoteQueueTrack) -> Track {
        Track(sourceID: queueTrack.sourceID, path: queueTrack.path, title: queueTrack.title)
    }

    // MARK: - State

    private func broadcastState() {
        guard !links.isEmpty else { return }
        let state = snapshot()
        for link in links.values {
            link.send(.state(state))
        }
    }

    private func snapshot() -> PlaybackState {
        PlaybackState(
            deviceName: Self.deviceName,
            isPlaying: player.isPlaying,
            isLoading: player.isLoading,
            currentTime: player.currentTime,
            duration: player.duration,
            currentIndex: player.currentIndex,
            queue: player.queue.map {
                RemoteTrack(id: $0.id, title: $0.title, artist: $0.artist, album: $0.album, duration: $0.duration)
            },
            errorMessage: player.errorMessage,
            audioFormat: player.audioFormatDescription
        )
    }

    // MARK: - Helpers

    /// A human-readable name for this device, used as the Bonjour service name.
    static var deviceName: String {
        #if targetEnvironment(macCatalyst)
        return Host.current().localizedName ?? "Mac"
        #elseif canImport(UIKit)
        return UIDevice.current.name
        #else
        return ProcessInfo.processInfo.hostName
        #endif
    }
}
