import Foundation
import AVFoundation
import MediaPlayer
import Combine
import Observation

/// Drives playback of audio tracks (FLAC, WAV, AIFF, ALAC, MP3, AAC/M4A, …)
/// using `AVAudioPlayer`. Maintains a queue,
/// resolves tracks to local files through the `SourceRegistry` (downloading
/// from SMB when needed), and integrates with the system Now Playing UI and
/// remote (lock-screen / control-center) commands.
///
/// Uses the Observation framework (`@Observable`, iOS 17+) so views only update
/// for the exact properties they read — e.g. the folder browser, which reads
/// `currentTrack`, no longer re-renders on every `currentTime` tick.
@MainActor
@Observable
final class AudioPlayer: NSObject {
    private(set) var queue: [Track] = []
    private(set) var currentIndex: Int?
    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var isLoading = false
    var errorMessage: String?
    /// Human-readable description of the current output format, e.g.
    /// "96 kHz · 24-bit · Stereo". Reflects the rate the hardware (USB DAC) runs at.
    private(set) var audioFormatDescription: String?

    var currentTrack: Track? {
        guard let i = currentIndex, queue.indices.contains(i) else { return nil }
        return queue[i]
    }

    @ObservationIgnored private unowned let registry: SourceRegistry
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var ticker: AnyCancellable?
    /// Resources backing the current track: the source file (an SMB download, to
    /// be released) and any decoder-produced temp file (to be deleted).
    @ObservationIgnored private var activeResource: (sourceID: String, sourceURL: URL, decodedTempURL: URL?)?
    @ObservationIgnored private var loadTask: Task<Void, Never>?

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

    /// Reorders queued tracks (Queue editor), keeping the current track current.
    func moveQueueItems(fromOffsets source: IndexSet, toOffset destination: Int) {
        let playing = currentTrack
        queue.move(fromOffsets: source, toOffset: destination)
        if let playing { currentIndex = queue.firstIndex(of: playing) }
    }

    /// Removes queued tracks (Queue editor). If the playing track is removed,
    /// playback advances to the track that takes its place, or stops if the queue
    /// empties.
    func removeQueueItems(atOffsets offsets: IndexSet) {
        let removingCurrent = currentIndex.map { offsets.contains($0) } ?? false
        let playing = currentTrack
        queue.remove(atOffsets: offsets)
        if removingCurrent {
            if queue.isEmpty {
                stop()
            } else {
                loadAndPlay(index: min(currentIndex ?? 0, queue.count - 1))
            }
        } else if let playing {
            currentIndex = queue.firstIndex(of: playing)
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
        audioFormatDescription = nil
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
                let sourceURL = try await source.fileURL(forPath: track.path)
                if Task.isCancelled { source.releaseTemporaryURL(sourceURL); return }

                // Decode formats Core Audio can't play natively (e.g. Ogg/Opus)
                // to a temporary PCM file off the main thread.
                let ext = (track.path as NSString).pathExtension.lowercased()
                let playable: PlayableAudio
                do {
                    playable = try await AudioDecoderRegistry.shared.prepare(sourceURL: sourceURL, fileExtension: ext)
                } catch {
                    source.releaseTemporaryURL(sourceURL)
                    throw error
                }
                if Task.isCancelled {
                    playable.cleanup()
                    source.releaseTemporaryURL(sourceURL)
                    return
                }
                self.startPlayback(playable: playable, sourceURL: sourceURL, track: track, sourceID: source.id)
            } catch is CancellationError {
                // ignored
            } catch {
                self.isLoading = false
                self.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func startPlayback(playable: PlayableAudio, sourceURL: URL, track: Track, sourceID: String) {
        cleanupTemp()
        do {
            // Match the hardware (USB DAC) to the file's native sample rate so the
            // system performs no resampling — bit-perfect output for the amp.
            let formatDescription = prepareHardwareOutput(for: playable.url)

            let newPlayer = try AVAudioPlayer(contentsOf: playable.url)
            newPlayer.delegate = self
            newPlayer.volume = 1.0      // unity gain; leave level control to the DAC/amp
            newPlayer.enableRate = false // no time-stretch/rate resampling in the path
            newPlayer.prepareToPlay()
            player = newPlayer
            duration = newPlayer.duration
            currentTime = 0
            isLoading = false
            audioFormatDescription = formatDescription
            // Track the backing resources so we can release/delete them later.
            activeResource = (sourceID, sourceURL, playable.temporaryURL)
            newPlayer.play()
            isPlaying = true
            startTicker()
            updateNowPlaying()
            loadMetadata(for: playable.url, trackID: track.id)
        } catch {
            playable.cleanup()
            registry.source(for: sourceID)?.releaseTemporaryURL(sourceURL)
            isLoading = false
            errorMessage = "Couldn't play \(track.title): \(error.localizedDescription)"
        }
    }

    /// Requests that the audio hardware run at `url`'s native sample rate (and
    /// channel count), avoiding sample-rate conversion on the way to a USB DAC.
    /// Returns a human-readable description of that format.
    private func prepareHardwareOutput(for url: URL) -> String? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.fileFormat
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setPreferredSampleRate(format.sampleRate)
        let channels = Int(format.channelCount)
        if channels > 0 {
            try? session.setPreferredOutputNumberOfChannels(min(channels, session.maximumOutputNumberOfChannels))
        }
        try? session.setActive(true)
        #endif
        return Self.describe(format)
    }

    private static func describe(_ format: AVAudioFormat) -> String {
        let kHz = format.sampleRate / 1000
        let rate = kHz == kHz.rounded() ? String(format: "%.0f kHz", kHz) : String(format: "%.1f kHz", kHz)
        var parts = [rate]
        if let bits = format.settings[AVLinearPCMBitDepthKey] as? Int, bits > 0 {
            let isFloat = (format.settings[AVLinearPCMIsFloatKey] as? Bool) ?? false
            parts.append(isFloat ? "\(bits)-bit float" : "\(bits)-bit")
        }
        switch format.channelCount {
        case 1: parts.append("Mono")
        case 2: parts.append("Stereo")
        default: parts.append("\(format.channelCount) ch")
        }
        return parts.joined(separator: " · ")
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
        if let active = activeResource {
            registry.source(for: active.sourceID)?.releaseTemporaryURL(active.sourceURL)
            if let decoded = active.decodedTempURL {
                try? FileManager.default.removeItem(at: decoded)
            }
        }
        activeResource = nil
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
