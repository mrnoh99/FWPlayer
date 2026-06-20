import Combine
import Foundation
import Network

/// Advertises FWPlayer on the local network and serves connected FWPlayerRemote
/// clients over a length-prefixed JSON protocol.
@MainActor
final class RemoteControlServer: ObservableObject {
    private unowned let player: AudioPlayer
    private unowned let registry: SourceRegistry
    private unowned let playlists: PlaylistManager
    private unowned let artwork: ArtworkStore
    /// The track id whose cover was last broadcast, so we send each cover once.
    private var lastArtworkTrackID: String?

    private var listener: NWListener?
    private var clients: [ObjectIdentifier: Client] = [:]
    private var cancellables = Set<AnyCancellable>()
    private let queue = DispatchQueue(label: "com.fwplayer.remote.server")
    private let deviceName: String
    private let bonjourName: String
    private let pairingPIN: String

    /// Six-digit PIN shown on the player; remotes must enter it to connect.
    @Published private(set) var displayPIN: String

    private struct Client {
        let link: RemoteLink
        var isAuthenticated = false
    }

    init(player: AudioPlayer, registry: SourceRegistry, playlists: PlaylistManager, artwork: ArtworkStore) {
        self.player = player
        self.registry = registry
        self.playlists = playlists
        self.artwork = artwork
        self.deviceName = HostDeviceName.current
        self.bonjourName = HostDeviceName.bonjourServiceName
        self.pairingPIN = Self.makePIN()
        self.displayPIN = pairingPIN
    }

    func start() {
        guard listener == nil else { return }

        do {
            let params = NWParameters.tcp
            params.includePeerToPeer = true
            let listener = try NWListener(using: params)
            listener.service = NWListener.Service(name: bonjourName, type: fwRemoteServiceType)
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            return
        }

        player.objectWillChange
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.broadcastState()
                self?.broadcastArtworkIfNeeded()
            }
            .store(in: &cancellables)

        artwork.objectWillChange
            .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.broadcastArtworkIfNeeded()
            }
            .store(in: &cancellables)

        // Re-send the library when playlists/favorites change so remotes can
        // reflect favorite state.
        playlists.objectWillChange
            .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.broadcastLibrary()
            }
            .store(in: &cancellables)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        clients.values.forEach { $0.link.cancel() }
        clients.removeAll()
        cancellables.removeAll()
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        let link = RemoteLink(connection: connection)
        let id = ObjectIdentifier(link)

        link.onMessage = { [weak self] message in
            self?.handle(message, from: id)
        }
        link.onStateChange = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.clients.removeValue(forKey: id)
            default:
                break
            }
        }

        clients[id] = Client(link: link)
        link.start()
        link.send(.pairingRequired(PairingRequired(deviceName: deviceName)))
    }

    // MARK: - Commands

    private func handle(_ message: RemoteMessage, from clientID: ObjectIdentifier) {
        guard case .command(let command) = message,
              var client = clients[clientID] else { return }

        switch command {
        case .authenticate(let pin):
            let normalized = pin.trimmingCharacters(in: .whitespacesAndNewlines)
            if normalized == pairingPIN {
                client.isAuthenticated = true
                clients[clientID] = client
                client.link.send(.authResult(AuthResult(success: true, message: nil)))
                pushState(to: client.link)
                if let art = currentArtworkMessage() { client.link.send(.artwork(art)) }
            } else {
                client.link.send(.authResult(AuthResult(success: false, message: "Incorrect PIN.")))
            }

        default:
            guard client.isAuthenticated else { return }
            clients[clientID] = client
            handleAuthenticated(command, from: client.link)
        }
    }

    private func handleAuthenticated(_ command: RemoteCommand, from link: RemoteLink) {
        switch command {
        case .requestState:
            pushState(to: link)

        case .togglePlayPause:
            player.togglePlayPause()

        case .play:
            player.resumePlayback()

        case .pause:
            player.pausePlayback()

        case .next:
            player.next()

        case .previous:
            player.previous()

        case .seek(let time):
            player.seek(to: time)

        case .playIndex(let index):
            player.play(at: index)

        case .stop:
            player.stop()

        case .toggleShuffle:
            player.toggleShuffle()

        case .cycleRepeat:
            player.cycleRepeatMode()

        case .requestLibrary:
            link.send(.library(buildLibrary()))

        case .browse(let sourceID, let path):
            Task {
                let listing = await buildListing(sourceID: sourceID, path: path, forceRefresh: false)
                link.send(.listing(listing))
            }

        case .setQueue(let tracks, let startAt, let playlistID):
            let queue = tracks.map { Track(sourceID: $0.sourceID, path: $0.path, title: $0.title) }
            guard !queue.isEmpty, queue.indices.contains(startAt) else { return }
            let playlistUUID = playlistID.flatMap { UUID(uuidString: $0) }
            player.play(tracks: queue, startAt: startAt, fromPlaylist: playlistUUID)

        case .enqueue(let tracks):
            let queue = tracks.map { Track(sourceID: $0.sourceID, path: $0.path, title: $0.title) }
            player.enqueue(tracks: queue)

        case .playNext(let tracks):
            // Insert in reverse so the list keeps its order right after the
            // current track.
            for remote in tracks.reversed() {
                player.playNext(Track(sourceID: remote.sourceID, path: remote.path, title: remote.title))
            }

        case .removeFromQueue(let indices):
            player.removeFromQueue(at: IndexSet(indices))

        case .clearQueue:
            player.clearQueue()

        case .moveQueue(let from, let to):
            player.moveQueue(fromOffsets: IndexSet(from), toOffset: to)

        case .playFolder(let sourceID, let path, let recursive):
            Task {
                await playFolder(sourceID: sourceID, path: path, recursive: recursive)
            }

        case .addToPlaylist(let playlistID, let tracks):
            guard let uuid = UUID(uuidString: playlistID) else { return }
            for remote in tracks {
                playlists.add(Track(sourceID: remote.sourceID, path: remote.path, title: remote.title), to: uuid)
            }

        case .movePlaylistEntry(let playlistID, let from, let to):
            guard let uuid = UUID(uuidString: playlistID) else { return }
            playlists.moveEntries(from: IndexSet(from), to: to, in: uuid)

        case .removePlaylistEntry(let playlistID, let indices):
            guard let uuid = UUID(uuidString: playlistID) else { return }
            playlists.removeEntries(at: IndexSet(indices), from: uuid)

        case .toggleFavorite(let remote):
            playlists.toggleFavorite(Track(sourceID: remote.sourceID, path: remote.path, title: remote.title))

        case .authenticate:
            break
        }
    }

    private func playFolder(sourceID: String, path: String, recursive: Bool) async {
        guard let source = registry.source(for: sourceID) else { return }
        do {
            let items = try await source.audioItems(in: path, recursive: recursive)
            guard !items.isEmpty else { return }
            let tracks = items.map { Track(sourceID: sourceID, item: $0) }
            player.play(tracks: tracks, startAt: 0, fromPlaylist: nil)
        } catch {
            player.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: - State push

    private func broadcastState() {
        let state = makePlaybackState()
        for client in clients.values where client.isAuthenticated {
            client.link.send(.state(state))
        }
    }

    private func pushState(to link: RemoteLink) {
        link.send(.state(makePlaybackState()))
    }

    private func broadcastLibrary() {
        let library = buildLibrary()
        for client in clients.values where client.isAuthenticated {
            client.link.send(.library(library))
        }
    }

    /// Builds the current track's artwork message, if a cover is cached.
    private func currentArtworkMessage() -> RemoteArtwork? {
        guard let track = player.currentTrack,
              let data = artwork.jpeg(for: track) else { return nil }
        return RemoteArtwork(trackID: track.id, jpegBase64: data.base64EncodedString())
    }

    /// Broadcasts the current cover once per track to every authenticated client.
    private func broadcastArtworkIfNeeded() {
        guard let track = player.currentTrack else { lastArtworkTrackID = nil; return }
        guard track.id != lastArtworkTrackID, let message = currentArtworkMessage() else { return }
        lastArtworkTrackID = track.id
        for client in clients.values where client.isAuthenticated {
            client.link.send(.artwork(message))
        }
    }

    private func makePlaybackState() -> PlaybackState {
        PlaybackState(
            deviceName: deviceName,
            isPlaying: player.isPlaying,
            isLoading: player.isLoading,
            currentTime: player.currentTime,
            duration: player.duration,
            currentIndex: player.currentIndex,
            queue: Self.remoteTracks(player.queue),
            history: Self.remoteTracks(player.history),
            errorMessage: player.errorMessage,
            audioFormat: player.currentTrack.flatMap { track in
                track.sampleRate.map { AudioFormatReader.formatSampleRate($0) }
            },
            isShuffled: player.isShuffled,
            repeatMode: player.repeatMode.rawValue
        )
    }

    private static func remoteTracks(_ tracks: [Track]) -> [RemoteTrack] {
        tracks.map {
            RemoteTrack(
                id: $0.id, title: $0.title, artist: $0.artist, album: $0.album,
                duration: $0.duration, sourceID: $0.sourceID, path: $0.path
            )
        }
    }

    private func buildLibrary() -> RemoteLibrary {
        RemoteLibrary(
            sources: registry.sources.map {
                RemoteSource(id: $0.id, displayName: $0.displayName, symbolName: $0.symbolName)
            },
            playlists: playlists.playlists.map { playlist in
                RemotePlaylist(
                    id: playlist.id.uuidString,
                    name: playlist.name,
                    tracks: playlist.entries.map {
                        RemoteQueueTrack(sourceID: $0.sourceID, path: $0.path, title: $0.title)
                    }
                )
            }
        )
    }

    private func buildListing(sourceID: String, path: String, forceRefresh: Bool) async -> RemoteListing {
        guard let source = registry.source(for: sourceID) else {
            return RemoteListing(sourceID: sourceID, path: path, items: [], error: "Source not found.")
        }

        do {
            var entries = try await (forceRefresh ? source.refresh(path: path) : source.list(path: path))
            // Retry once from disk when a poisoned cache returns an empty folder that
            // the parent listing still advertises (common after a failed pre-scan).
            if entries.isEmpty, !forceRefresh, await folderAdvertisedInParent(source: source, path: path) {
                entries = try await source.refresh(path: path)
            }
            let items = entries.compactMap { item -> RemoteFileItem? in
                switch item.kind {
                case .directory:
                    return RemoteFileItem(path: item.path, name: item.name, kind: .directory, size: item.size)
                case .audio:
                    return RemoteFileItem(path: item.path, name: item.name, kind: .audio, size: item.size)
                case .other:
                    return nil
                }
            }
            return RemoteListing(sourceID: sourceID, path: path, items: items, error: nil)
        } catch {
            return RemoteListing(
                sourceID: sourceID,
                path: path,
                items: [],
                error: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            )
        }
    }

    /// Returns true when the parent folder's cached listing still contains `path`.
    private func folderAdvertisedInParent(source: any FileSource, path: String) async -> Bool {
        guard !path.isEmpty else { return false }
        let parent = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        guard let parentEntries = try? await source.list(path: parent) else { return false }
        return parentEntries.contains { $0.kind == .directory && $0.path == path && $0.name == name }
    }

    private static func makePIN() -> String {
        String(format: "%06d", Int.random(in: 0...999_999))
    }
}
