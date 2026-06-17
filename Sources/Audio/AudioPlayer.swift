import Foundation
import AVFoundation
import MediaPlayer
import Combine

/// Drives playback of audio tracks (FLAC, WAV, AIFF, ALAC, MP3, AAC/M4A, …)
/// using `AVAudioPlayer`. Maintains a queue,
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

    var currentTrack: Track? {
        guard let i = currentIndex, queue.indices.contains(i) else { return nil }
        return queue[i]
    }

    private unowned let registry: SourceRegistry
    private var player: AVAudioPlayer?
    private var ticker: AnyCancellable?
    /// Temporary download (e.g. from SMB) currently in use, to be cleaned up.
    private var activeTempURL: (sourceID: String, url: URL)?
    private var loadTask: Task<Void, Never>?

    init(registry: SourceRegistry) {
        self.registry = registry
        super.init()
        configureAudioSession()
        configureRemoteCommands()
    }

    // MARK: - Public transport

    /// Replaces the queue with `tracks` and starts playback at `index`.
    func play(tracks: [Track], startAt index: Int) {
        guard tracks.indices.contains(index) else { return }
        queue = tracks
        loadAndPlay(index: index)
    }

    /// Jumps to and plays the track at `index` within the current queue. Used by
    /// the remote-control server to honor "play this track" taps from a remote.
    func playQueueIndex(_ index: Int) {
        guard queue.indices.contains(index) else { return }
        loadAndPlay(index: index)
    }

    /// Appends `tracks` to the end of the queue. If nothing is currently loaded,
    /// playback starts from the first appended track. Used by the remote to add
    /// to the queue without interrupting the current track.
    func enqueue(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        let shouldStart = currentIndex == nil
        let startIndex = queue.count
        queue.append(contentsOf: tracks)
        if shouldStart {
            loadAndPlay(index: startIndex)
        }
    }

    func togglePlayPause() {
        guard let player else {
            if let i = currentIndex { loadAndPlay(index: i) }
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
    }

    func next() {
        guard let i = currentIndex, i + 1 < queue.count else {
            stop()
            return
        }
        loadAndPlay(index: i + 1)
    }

    func previous() {
        // Restart current track if more than 3s in, otherwise go to previous.
        if currentTime > 3, currentIndex != nil {
            seek(to: 0)
            return
        }
        guard let i = currentIndex, i > 0 else {
            seek(to: 0)
            return
        }
        loadAndPlay(index: i - 1)
    }

    func seek(to time: TimeInterval) {
        guard let player else { return }
        player.currentTime = max(0, min(time, player.duration))
        currentTime = player.currentTime
        updateNowPlaying()
    }

    func stop() {
        loadTask?.cancel()
        player?.stop()
        player = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        currentIndex = nil
        ticker?.cancel()
        cleanupTemp()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: - Loading

    private func loadAndPlay(index: Int) {
        guard queue.indices.contains(index) else { return }
        loadTask?.cancel()
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
                if Task.isCancelled { source.releaseTemporaryURL(url); return }
                self.startPlayback(url: url, track: track, sourceID: source.id)
            } catch is CancellationError {
                // ignored
            } catch {
                self.isLoading = false
                self.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func startPlayback(url: URL, track: Track, sourceID: String) {
        cleanupTemp()
        do {
            let newPlayer = try AVAudioPlayer(contentsOf: url)
            newPlayer.delegate = self
            newPlayer.prepareToPlay()
            player = newPlayer
            duration = newPlayer.duration
            currentTime = 0
            isLoading = false
            // Track the temp file so we can delete it when we move on.
            activeTempURL = (sourceID, url)
            newPlayer.play()
            isPlaying = true
            startTicker()
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
            await MainActor.run {
                guard let self,
                      let idx = self.queue.firstIndex(where: { $0.id == trackID }) else { return }
                var track = self.queue[idx]
                if let artist { track.artist = artist }
                if let album { track.album = album }
                // The file-name-derived title is kept; embedded title is only a fallback.
                self.queue[idx] = track
                if self.currentIndex == idx { self.updateNowPlaying() }
            }
        }
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
            MainActor.assumeIsolated { self?.previous() }; return .success
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
