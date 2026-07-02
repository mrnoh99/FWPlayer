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
    /// The track id whose catalog details were last broadcast, so each track's
    /// details (which resolve asynchronously) are sent once.
    private var lastCatalogTrackID: String?
    /// The last state we sent, and when, so a stream of pure `currentTime` ticks
    /// during playback doesn't flood the link (the remote interpolates time
    /// itself). Meaningful changes still go out immediately.
    private var lastSentState: PlaybackState?
    private var lastTimeSync = Date.distantPast

    private var listener: NWListener?
    private var clients: [ObjectIdentifier: Client] = [:]
    private var cancellables = Set<AnyCancellable>()
    private let queue = DispatchQueue(label: "com.fwplayer.remote.server")
    private let deviceName: String
    private let bonjourName: String
    private let pairingPIN: String

    /// Single-digit PIN shown on the player; remotes must enter it to connect.
    @Published private(set) var displayPIN: String

    /// Whether the Bonjour listener is up and advertising. Surfaced in the UI so
    /// a failure to advertise (e.g. Local Network permission not granted on
    /// macOS) is visible instead of silent.
    @Published private(set) var isListening = false
    /// Human-readable reason the listener isn't ready, when it isn't.
    @Published private(set) var networkStatus: String?

    /// Set once the Combine/timer broadcasts are installed, so a listener
    /// restart (after a failure) doesn't stack duplicate subscriptions.
    private var didInstallBroadcasts = false
    private var isRestarting = false

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
        startListener()
        installBroadcasts()
    }

    /// Creates and starts the Bonjour listener. Split out from `start()` so it
    /// can be retried on failure (e.g. after the user grants Local Network
    /// permission on macOS) without re-installing the broadcast subscriptions.
    private func startListener() {
        guard listener == nil else { return }
        do {
            let tcpOptions = NWProtocolTCP.Options()
            tcpOptions.enableKeepalive = true
            tcpOptions.keepaliveIdle = 4
            tcpOptions.keepaliveInterval = 2
            tcpOptions.keepaliveCount = 3
            let params = NWParameters(tls: nil, tcp: tcpOptions)
            // Advertise on every available interface (Wi‑Fi *and* wired
            // Ethernet on a multi-homed Mac) plus peer-to-peer, so a remote on
            // any of them can find and reach the player.
            params.includePeerToPeer = true
            let listener = try NWListener(using: params)
            listener.service = NWListener.Service(name: bonjourName, type: fwRemoteServiceType)
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in self?.handleListenerState(state) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            NSLog("[RemoteServer] listener creation failed: \(error)")
            networkStatus = "Couldn't start: \(error.localizedDescription)"
            isListening = false
            scheduleListenerRestart()
        }
    }

    /// Reacts to listener lifecycle. On macOS the listener sits in `.waiting`
    /// until Local Network permission is granted, then flips to `.ready` on its
    /// own; a hard `.failed` gets a delayed restart.
    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            isListening = true
            networkStatus = nil
            NSLog("[RemoteServer] advertising \"\(bonjourName)\" \(fwRemoteServiceType)")
        case .waiting(let error):
            isListening = false
            networkStatus = "Waiting for network/permission: \(error.localizedDescription)"
            NSLog("[RemoteServer] waiting: \(error)")
        case .failed(let error):
            isListening = false
            networkStatus = "Network error: \(error.localizedDescription)"
            NSLog("[RemoteServer] failed: \(error)")
            scheduleListenerRestart()
        case .cancelled:
            isListening = false
        default:
            break
        }
    }

    private func scheduleListenerRestart() {
        guard !isRestarting else { return }
        isRestarting = true
        listener?.cancel()
        listener = nil
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self else { return }
            self.isRestarting = false
            self.startListener()
        }
    }

    private func installBroadcasts() {
        guard !didInstallBroadcasts else { return }
        didInstallBroadcasts = true

        player.objectWillChange
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.broadcastState()
                self?.broadcastArtworkIfNeeded()
                self?.broadcastCatalogInfoIfNeeded()
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

        // Periodic keepalive: resend state every couple of seconds (deduped, so
        // it's cheap) so an idle/paused link stays warm and a remote can tell a
        // dead connection from a quiet one.
        Timer.publish(every: 2, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.broadcastState() }
            .store(in: &cancellables)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isListening = false
        networkStatus = nil
        clients.values.forEach { $0.link.cancel() }
        clients.removeAll()
        cancellables.removeAll()
        didInstallBroadcasts = false
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

        // PIN-less: authenticate the client immediately and push the current
        // state so the remote connects automatically (no pairing step).
        clients[id] = Client(link: link, isAuthenticated: true)
        link.start()
        link.send(.authResult(AuthResult(success: true, message: nil)))
        pushState(to: link)
        if let art = currentArtworkMessage() { link.send(.artwork(art)) }
        if let details = currentCatalogMessage() { link.send(.catalogInfo(details)) }
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
                if let details = currentCatalogMessage() { client.link.send(.catalogInfo(details)) }
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

        // Collapse pure time ticks: if nothing but currentTime changed, resync at
        // most once a second so browsing/commands aren't starved during playback.
        var meaningfulChanged = true
        if var last = lastSentState {
            last.currentTime = state.currentTime
            meaningfulChanged = (last != state)
        }
        let now = Date()
        if !meaningfulChanged && now.timeIntervalSince(lastTimeSync) < 1.0 {
            return
        }
        lastSentState = state
        lastTimeSync = now

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

    /// Builds the current track's catalog-details message, if details have
    /// resolved (they arrive asynchronously after the track starts).
    private func currentCatalogMessage() -> RemoteCatalogInfo? {
        guard let track = player.currentTrack,
              let info = player.currentCatalogInfo,
              info.hasDisplayableDetails else { return nil }
        return RemoteCatalogInfo(
            trackID: track.id,
            albumTitle: info.albumTitle,
            artistName: info.artistName,
            genre: info.genre,
            year: info.year,
            releaseDate: info.releaseDate.map { Self.releaseDateFormatter.string(from: $0) },
            trackCount: info.trackCount,
            recordLabel: info.recordLabel,
            contentRating: info.contentRating,
            editorialNotes: info.editorialNotes,
            copyright: info.copyright,
            lyrics: info.lyrics,
            source: info.source
        )
    }

    /// Broadcasts the current track's details once they resolve, once per track.
    private func broadcastCatalogInfoIfNeeded() {
        guard let track = player.currentTrack else { lastCatalogTrackID = nil; return }
        guard track.id != lastCatalogTrackID, let message = currentCatalogMessage() else { return }
        lastCatalogTrackID = track.id
        for client in clients.values where client.isAuthenticated {
            client.link.send(.catalogInfo(message))
        }
    }

    private static let releaseDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

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
                year: $0.year, genre: $0.genre, duration: $0.duration,
                sourceID: $0.sourceID, path: $0.path
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
        String(Int.random(in: 0...9))
    }
}
