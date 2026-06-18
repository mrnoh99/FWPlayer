import Foundation
import AVFoundation
import MediaPlayer
import Combine

/// Drives playback of FLAC/WAV tracks using `AVAudioPlayer`. Maintains a queue,
/// resolves tracks to local files through the `SourceRegistry` (downloading
/// from SMB when needed), and integrates with the system Now Playing UI and
/// remote (lock-screen / control-center) commands.
@MainActor
final class AudioPlayer: NSObject, ObservableObject {
    @Published private(set) var queue: [Track] = []
    @Published private(set) var currentIndex: Int?
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    /// Bumped on play/pause, skip, seek, and stop so list views can snap focus back to the playing row.
    @Published private(set) var transportEventID = 0

    var currentTrack: Track? {
        guard let i = currentIndex, queue.indices.contains(i) else { return nil }
        return queue[i]
    }

    /// When set, next/previous follow the live playlist order.
    @Published private(set) var activePlaylistID: UUID?

    var canGoNext: Bool {
        guard let i = currentIndex, queue.indices.contains(i) else { return false }
        return queue.count > 1
    }

    var canGoPrevious: Bool {
        guard let i = currentIndex, queue.indices.contains(i) else { return false }
        if queue.count > 1 { return true }
        return currentTime > 3
    }

    private unowned let registry: SourceRegistry
    private unowned let playlists: PlaylistManager
    private var player: AVAudioPlayer?
    private var ticker: AnyCancellable?
    /// Temporary download (e.g. from SMB) currently in use, to be cleaned up.
    private var activeTempURL: (sourceID: String, url: URL)?
    private var loadTask: Task<Void, Never>?

    init(registry: SourceRegistry, playlists: PlaylistManager) {
        self.registry = registry
        self.playlists = playlists
        super.init()
        configureAudioSession()
        configureRemoteCommands()
    }

    // MARK: - Public transport

    /// Replaces the queue with `tracks` and starts playback at `index`.
    /// Pass `fromPlaylist` when starting from a playlist so next/previous stay in sync.
    func play(tracks: [Track], startAt index: Int, fromPlaylist playlistID: UUID? = nil) {
        guard tracks.indices.contains(index) else { return }
        activePlaylistID = playlistID
        queue = tracks
        loadAndPlay(index: index)
    }

    func togglePlayPause() {
        guard let player else {
            if let i = currentIndex { loadAndPlay(index: i) }
            noteTransportEvent()
            return
        }
        if player.isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
        updateNowPlaying()
        noteTransportEvent()
    }

    func next() {
        guard let i = resolvedCurrentIndex() ?? currentIndex,
              queue.indices.contains(i),
              queue.count > 1 else { return }

        let nextIndex = i + 1 < queue.count ? i + 1 : 0
        if isPlaying {
            loadAndPlay(index: nextIndex)
        } else {
            selectTrack(at: nextIndex)
        }
        noteTransportEvent()
    }

    func previous() {
        guard let i = resolvedCurrentIndex() ?? currentIndex,
              queue.indices.contains(i) else { return }

        if isPlaying {
            if i == 0 {
                guard queue.count > 1 else {
                    if currentTime > 3 { seek(to: 0) }
                    return
                }
                loadAndPlay(index: queue.count - 1)
            } else if currentTime > 3 {
                seek(to: 0)
            } else {
                loadAndPlay(index: i - 1)
            }
        } else {
            guard queue.count > 1 else { return }
            let previousIndex = i == 0 ? queue.count - 1 : i - 1
            selectTrack(at: previousIndex)
        }
        noteTransportEvent()
    }

    func seek(to time: TimeInterval) {
        guard let player else { return }
        let duration = player.duration
        guard duration.isFinite, duration > 0 else {
            player.currentTime = 0
            currentTime = 0
            updateNowPlaying()
            return
        }
        let clamped = max(0, min(time, duration))
        guard clamped.isFinite else { return }
        player.currentTime = clamped
        currentTime = player.currentTime
        updateNowPlaying()
        noteTransportEvent()
    }

    func stop() {
        loadTask?.cancel()
        tearDownPlayback(keepQueue: false)
        isLoading = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        noteTransportEvent()
    }

    private func noteTransportEvent() {
        transportEventID += 1
    }

    // MARK: - Loading

    /// Keeps the queue aligned with the active playlist and returns the current index.
    private func resolvedCurrentIndex() -> Int? {
        guard let playlistID = activePlaylistID,
              let playlist = playlists.playlist(for: playlistID) else {
            return currentIndex
        }

        let tracks = playlist.tracks
        guard !tracks.isEmpty else {
            stop()
            return nil
        }

        let playingID = currentTrack?.id
        queue = tracks

        let resolved: Int
        if let playingID, let index = tracks.firstIndex(where: { $0.id == playingID }) {
            resolved = index
        } else if let i = currentIndex, tracks.indices.contains(i) {
            resolved = i
        } else {
            resolved = 0
        }

        currentIndex = resolved
        return resolved
    }

    private func loadAndPlay(index: Int) {
        guard queue.indices.contains(index) else { return }
        loadTask?.cancel()
        tearDownPlayback(keepQueue: true)
        currentIndex = index
        let track = queue[index]
        isLoading = true
        errorMessage = nil

        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                guard let source = self.registry.source(for: track.sourceID) else {
                    throw FileSourceError.notConnected
                }
                let url = try await source.fileURL(forPath: track.path)
                try Task.checkCancellation()
                if Task.isCancelled { source.releaseTemporaryURL(url); return }
                self.startPlayback(url: url, track: track, sourceID: source.id, autoPlay: true)
            } catch is CancellationError {
                // ignored
            } catch {
                self.isLoading = false
                self.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    /// Stops the active player without clearing the queue or current index.
    private func tearDownPlayback(keepQueue: Bool) {
        player?.stop()
        player?.delegate = nil
        player = nil
        ticker?.cancel()
        cleanupTemp()
        isPlaying = false
        currentTime = 0
        duration = 0
        if !keepQueue {
            currentIndex = nil
            activePlaylistID = nil
            queue = []
        }
    }

    /// Moves the playhead to another queue entry without starting playback.
    private func selectTrack(at index: Int) {
        guard queue.indices.contains(index) else { return }
        loadTask?.cancel()
        tearDownPlayback(keepQueue: true)
        currentIndex = index
        isLoading = false
        updateNowPlaying()
    }

    private func startPlayback(url: URL, track: Track, sourceID: String, autoPlay: Bool = true) {
        cleanupTemp()
        do {
            let newPlayer = try AVAudioPlayer(contentsOf: url)
            newPlayer.delegate = self
            newPlayer.prepareToPlay()
            player = newPlayer
            duration = newPlayer.duration
            currentTime = 0
            isLoading = false
            activeTempURL = (sourceID, url)
            if autoPlay {
                newPlayer.play()
                isPlaying = true
                startTicker()
            } else {
                isPlaying = false
            }
            updateTrackSampleRate(trackID: track.id, sampleRate: newPlayer.format.sampleRate)
            updateNowPlaying()
            loadMetadata(for: url, trackID: track.id)
        } catch {
            isLoading = false
            errorMessage = "Couldn't play \(track.title): \(error.localizedDescription)"
        }
    }

    private func startTicker() {
        ticker?.cancel()
        ticker = Timer.publish(every: 0.5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self, let player = self.player else { return }
                self.currentTime = player.currentTime
            }
    }

    private func cleanupTemp() {
        if let active = activeTempURL, let source = registry.source(for: active.sourceID) {
            source.releaseTemporaryURL(active.url)
        }
        activeTempURL = nil
    }

    // MARK: - Metadata

    /// Asynchronously enriches the current track with embedded title/artist/album.
    private func loadMetadata(for url: URL, trackID: String) {
        Task { [weak self] in
            let asset = AVURLAsset(url: url)
            guard let metadata = try? await asset.load(.commonMetadata) else { return }
            var artist: String?
            var album: String?
            for item in metadata {
                guard let key = item.commonKey else { continue }
                let value = try? await item.load(.stringValue)
                switch key {
                case .commonKeyArtist: artist = value
                case .commonKeyAlbumName: album = value
                default: break
                }
            }
            let sampleRate = await AudioFormatReader.readSampleRate(from: url)
            await MainActor.run {
                guard let self,
                      let idx = self.queue.firstIndex(where: { $0.id == trackID }) else { return }
                var track = self.queue[idx]
                if let artist { track.artist = artist }
                if let album { track.album = album }
                if let sampleRate, track.sampleRate == nil { track.sampleRate = sampleRate }
                // The file-name-derived title is kept; embedded title is only a fallback.
                var updated = self.queue
                updated[idx] = track
                self.queue = updated
                if self.currentIndex == idx { self.updateNowPlaying() }
            }
        }
    }

    private func updateTrackSampleRate(trackID: String, sampleRate: Double) {
        guard sampleRate > 0,
              let idx = queue.firstIndex(where: { $0.id == trackID }) else { return }
        var updated = queue
        updated[idx].sampleRate = sampleRate
        queue = updated
    }

    // MARK: - Audio session

    private func configureAudioSession() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
        #endif
    }

    // MARK: - Remote commands & Now Playing

    private func configureRemoteCommands() {
        // Remote command handlers are delivered on the main thread, so it is
        // safe to assume main-actor isolation when calling our @MainActor API.
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.togglePlayPause() }; return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.togglePlayPause() }; return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.togglePlayPause() }; return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.next() }; return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            var result = MPRemoteCommandHandlerStatus.commandFailed
            MainActor.assumeIsolated {
                guard let self, self.canGoPrevious else { return }
                self.previous()
                result = .success
            }
            return result
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            MainActor.assumeIsolated { self?.seek(to: event.positionTime) }
            return .success
        }
    }

    private func updateNowPlaying() {
        guard let track = currentTrack else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]
        if let artist = track.artist { info[MPMediaItemPropertyArtist] = artist }
        if let album = track.album { info[MPMediaItemPropertyAlbumTitle] = album }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}

extension AudioPlayer: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            self?.next()
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in
            self?.errorMessage = error?.localizedDescription ?? "Playback decode error."
            self?.next()
        }
    }
}
