import Foundation
import AVFoundation
import MediaPlayer
import Combine
#if os(iOS)
import UIKit
#endif

/// Repeat behavior, cycled Apple Music–style: off → all (loop queue) → one (loop track).
enum RepeatMode: Int {
    case off, all, one
}

/// Drives playback of FLAC/WAV tracks using `AVAudioPlayer`. Maintains a queue,
/// resolves tracks to local files through the `SourceRegistry` (downloading
/// from SMB when needed), and integrates with the system Now Playing UI and
/// remote (lock-screen / control-center) commands.
@MainActor
final class AudioPlayer: NSObject, ObservableObject {
    @Published private(set) var queue: [Track] = []
    @Published private(set) var currentIndex: Int?
    @Published private(set) var isPlaying = false {
        didSet { updateBackgroundKeepAlive() }
    }
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    /// Bumped on play/pause, skip, seek, and stop so list views can snap focus back to the playing row.
    @Published private(set) var transportEventID = 0
    /// Apple Music Catalog (MusicKit) details for the current track, resolved
    /// asynchronously after it starts. Drives the player's detail panel and is
    /// forwarded to the remote. Cleared whenever the track changes.
    @Published private(set) var currentCatalogInfo: MusicKitCatalog.AlbumInfo?

    var currentTrack: Track? {
        guard let i = currentIndex, queue.indices.contains(i) else { return nil }
        return queue[i]
    }

    /// When set, next/previous follow the live playlist order.
    @Published private(set) var activePlaylistID: UUID?

    /// Apple Music–style shuffle and repeat.
    @Published var repeatMode: RepeatMode = .off
    @Published private(set) var isShuffled = false
    /// The pre-shuffle (sequential) order, so shuffle can be turned back off.
    private var unshuffledQueue: [Track] = []

    /// Recently played tracks, most recent first (session history).
    @Published private(set) var history: [Track] = []

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
    /// Album-artwork cache, used to enrich the playing track and feed the UI.
    let artwork: ArtworkStore
    private unowned let playlists: PlaylistManager
    private var player: AVAudioPlayer?
    private var ticker: AnyCancellable?
    /// Resources backing the current track: the source file (an SMB download, to
    /// be released) and any decoder-produced temp file (to be deleted).
    private var activeResource: (sourceID: String, sourceURL: URL, decodedTempURL: URL?, trackID: String)?
    private var loadTask: Task<Void, Never>?
    /// Pre-downloaded local copies of upcoming queue tracks (keyed by track id) so
    /// playback starts instantly when their turn comes, instead of waiting on a
    /// fresh SMB download. `prefetchTasks` holds the in-flight downloads.
    private var prefetched: [String: (sourceID: String, url: URL)] = [:]
    private var prefetchTasks: [String: Task<Void, Never>] = [:]
    /// How many upcoming tracks to pre-download.
    private let prefetchDepth = 5
    /// Recently played tracks' downloaded files, kept after playback so replaying
    /// them (e.g. from History or going back) is instant. Bounded LRU.
    private var recentlyPlayed: [String: (sourceID: String, url: URL)] = [:]
    private var recentlyPlayedOrder: [String] = []
    private let recentlyPlayedCap = 10

    /// Whether the player should stay resident (and remote-controllable) while
    /// backgrounded with the screen off, even when nothing is actively playing.
    /// Persisted so the choice survives relaunch; defaults on so a remote can
    /// wake the iPad's player without anyone touching it. Set to `false` to let
    /// iOS suspend the app normally when paused (saves battery).
    @Published var backgroundRemoteEnabled: Bool {
        didSet {
            UserDefaults.standard.set(backgroundRemoteEnabled, forKey: Self.backgroundRemoteKey)
            updateBackgroundKeepAlive()
        }
    }
    private static let backgroundRemoteKey = "backgroundRemoteEnabled"

    /// Tracks whether the app is currently backgrounded (screen off / another
    /// app foregrounded), so the keep-alive only runs when it's actually needed.
    private var isInBackground = false
    #if os(iOS)
    private let keepAlive = BackgroundAudioKeepAlive()
    #endif

    init(registry: SourceRegistry, playlists: PlaylistManager, artwork: ArtworkStore) {
        self.registry = registry
        self.playlists = playlists
        self.artwork = artwork
        if UserDefaults.standard.object(forKey: Self.backgroundRemoteKey) == nil {
            self.backgroundRemoteEnabled = true
        } else {
            self.backgroundRemoteEnabled = UserDefaults.standard.bool(forKey: Self.backgroundRemoteKey)
        }
        super.init()
        configureAudioSession()
        configureRemoteCommands()
        observeAppLifecycle()
        observeAudioSessionEvents()
    }

    // MARK: - Public transport

    /// Replaces the queue with `tracks` and starts playback at `index`.
    /// Pass `fromPlaylist` when starting from a playlist so next/previous stay in sync.
    func play(tracks: [Track], startAt index: Int, fromPlaylist playlistID: UUID? = nil) {
        guard tracks.indices.contains(index) else { return }
        unshuffledQueue = tracks
        if isShuffled {
            // Shuffle stays on across new queues; play the chosen track first.
            activePlaylistID = nil
            let startTrack = tracks[index]
            var rest = tracks
            rest.remove(at: index)
            rest.shuffle()
            queue = [startTrack] + rest
            loadAndPlay(index: 0)
        } else {
            activePlaylistID = playlistID
            queue = tracks
            loadAndPlay(index: index)
        }
    }

    /// Cycles repeat off → all → one (Apple Music order).
    func cycleRepeatMode() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
        updateNowPlaying()
    }

    /// Toggles shuffle, keeping the current track playing.
    func toggleShuffle() {
        let playing = currentTrack
        if isShuffled {
            if !unshuffledQueue.isEmpty { queue = unshuffledQueue }
            isShuffled = false
        } else {
            activePlaylistID = nil      // detach from live playlist order
            unshuffledQueue = queue
            var rest = queue
            if let playing, let idx = rest.firstIndex(of: playing) { rest.remove(at: idx) }
            rest.shuffle()
            queue = (playing.map { [$0] } ?? []) + rest
            isShuffled = true
        }
        if let playing { currentIndex = queue.firstIndex(of: playing) }
        updateNowPlaying()
        noteTransportEvent()
    }

    func togglePlayPause() {
        guard let player else {
            if let i = currentIndex { loadAndPlay(index: i) }
            noteTransportEvent()
            return
        }
        if player.isPlaying {
            pausePlayback()
        } else {
            resumePlayback()
        }
    }

    func resumePlayback() {
        guard let player else {
            if let i = currentIndex { loadAndPlay(index: i) }
            noteTransportEvent()
            return
        }
        guard !player.isPlaying else { return }
        player.play()
        isPlaying = true
        startTicker()
        updateNowPlaying()
        noteTransportEvent()
    }

    func pausePlayback() {
        guard let player, player.isPlaying else { return }
        player.pause()
        isPlaying = false
        updateNowPlaying()
        noteTransportEvent()
    }

    /// Starts playback at an existing queue index.
    func play(at index: Int) {
        guard queue.indices.contains(index) else { return }
        loadAndPlay(index: index)
        noteTransportEvent()
    }

    /// Appends tracks to the current queue without interrupting playback.
    func enqueue(tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        if queue.isEmpty {
            play(tracks: tracks, startAt: 0, fromPlaylist: nil)
            return
        }
        activePlaylistID = nil
        queue.append(contentsOf: tracks)
        unshuffledQueue.append(contentsOf: tracks)
        prefetchUpcoming()
    }

    /// Inserts a track to play immediately after the current one ("Play Next").
    /// If nothing is playing, starts it right away.
    func playNext(_ track: Track) {
        guard currentIndex != nil, !queue.isEmpty else {
            play(tracks: [track], startAt: 0)
            return
        }
        activePlaylistID = nil
        let insertAt = min((currentIndex ?? -1) + 1, queue.count)
        queue.insert(track, at: insertAt)
        unshuffledQueue.append(track)
        prefetchUpcoming()
        noteTransportEvent()
    }

    /// Reorders queued tracks (Queue editor), keeping the current track current.
    func moveQueue(fromOffsets source: IndexSet, toOffset destination: Int) {
        let playing = currentTrack
        queue.move(fromOffsets: source, toOffset: destination)
        if let playing { currentIndex = queue.firstIndex(of: playing) }
        prefetchUpcoming()
        noteTransportEvent()
    }

    /// Empties the queue and stops playback ("Clear").
    func clearQueue() {
        stop()
        unshuffledQueue = []
        isShuffled = false
    }

    // MARK: - Play history

    /// Records a track as just-played at the top of the history (deduped, capped).
    private func recordHistory(_ track: Track) {
        history.removeAll { $0.id == track.id }
        history.insert(track, at: 0)
        if history.count > 100 { history.removeLast(history.count - 100) }
    }

    func removeFromHistory(at offsets: IndexSet) {
        history.remove(atOffsets: offsets)
    }

    func clearHistory() {
        history.removeAll()
    }

    /// Removes tracks at the given indices. Stops playback if the queue becomes empty.
    func removeFromQueue(at offsets: IndexSet) {
        guard !offsets.isEmpty, !queue.isEmpty else { return }
        activePlaylistID = nil

        let oldIndex = currentIndex ?? 0
        let removingCurrent = offsets.contains(oldIndex)

        var updated = queue
        var removedIDs = Set<String>()
        for index in offsets.sorted(by: >) where updated.indices.contains(index) {
            removedIDs.insert(updated[index].id)
            updated.remove(at: index)
        }
        unshuffledQueue.removeAll { removedIDs.contains($0.id) }

        guard !updated.isEmpty else {
            stop()
            return
        }

        let removedBefore = offsets.filter { $0 < oldIndex }.count
        let newIndex = removingCurrent
            ? min(oldIndex, updated.count - 1)
            : oldIndex - removedBefore

        queue = updated

        if removingCurrent {
            if isPlaying {
                loadAndPlay(index: newIndex)
            } else {
                selectTrack(at: newIndex)
            }
        } else {
            currentIndex = newIndex
            updateNowPlaying()
        }
        prefetchUpcoming()
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
        clearPrefetch()
        tearDownPlayback(keepQueue: false)
        clearRecentlyPlayed()
        isLoading = false
        currentCatalogInfo = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        noteTransportEvent()
    }

    // MARK: - Prefetch

    /// The next queue indices that will play after the current one (with repeat-all
    /// wraparound), used to pre-download upcoming tracks.
    private func upcomingIndices() -> [Int] {
        guard let current = currentIndex, !queue.isEmpty else { return [] }
        var result: [Int] = []
        var idx = current
        while result.count < prefetchDepth {
            let nextIdx: Int
            if idx + 1 < queue.count {
                nextIdx = idx + 1
            } else if repeatMode == .all {
                nextIdx = 0
            } else {
                break
            }
            if nextIdx == current { break }   // repeat-one / single-item queue
            result.append(nextIdx)
            idx = nextIdx
        }
        return result
    }

    private func upcomingTrackIDs() -> Set<String> {
        Set(upcomingIndices().map { queue[$0].id })
    }

    /// Pre-downloads upcoming tracks to local temp files (and releases prefetched
    /// files no longer upcoming). Local sources are skipped — they're already instant.
    private func prefetchUpcoming() {
        let wanted = upcomingTrackIDs()

        for (trackID, task) in prefetchTasks where !wanted.contains(trackID) {
            task.cancel()
            prefetchTasks[trackID] = nil
        }
        for (trackID, resource) in prefetched where !wanted.contains(trackID) {
            registry.source(for: resource.sourceID)?.releaseTemporaryURL(resource.url)
            prefetched[trackID] = nil
        }

        for index in upcomingIndices() {
            let track = queue[index]
            guard prefetched[track.id] == nil, prefetchTasks[track.id] == nil,
                  recentlyPlayed[track.id] == nil else { continue }   // already cached
            guard let source = registry.source(for: track.sourceID) else { continue }
            // Never read ahead on an optical drive: ripping upcoming tracks while
            // the current one plays makes the drive seek-thrash and macOS can
            // eject the disc as unreadable. CD tracks are ripped just-in-time.
            if source.kind == .audioCD { continue }
            if source.directURL(forPath: track.path) != nil { continue }   // local: no download

            prefetchTasks[track.id] = Task { [weak self] in
                let url = try? await source.fileURL(forPath: track.path)
                await MainActor.run {
                    guard let self else {
                        if let url { source.releaseTemporaryURL(url) }
                        return
                    }
                    self.prefetchTasks[track.id] = nil
                    guard let url else { return }
                    if self.upcomingTrackIDs().contains(track.id) {
                        self.prefetched[track.id] = (source.id, url)
                    } else {
                        source.releaseTemporaryURL(url)   // no longer upcoming
                    }
                }
            }
        }
    }

    /// Cancels in-flight prefetches and releases every prefetched temp file.
    private func clearPrefetch() {
        prefetchTasks.values.forEach { $0.cancel() }
        prefetchTasks.removeAll()
        for resource in prefetched.values {
            registry.source(for: resource.sourceID)?.releaseTemporaryURL(resource.url)
        }
        prefetched.removeAll()
    }

    private func noteTransportEvent() {
        transportEventID += 1
    }

    /// Advances when the current track finishes playing, honoring the repeat mode.
    private func advanceAfterPlaybackEnded() {
        switch repeatMode {
        case .one:
            if let i = currentIndex, queue.indices.contains(i) {
                loadAndPlay(index: i)            // replay the same track
            }
        case .all:
            if queue.count <= 1 {
                if let i = currentIndex { loadAndPlay(index: i) }
            } else {
                next()                            // wraps to the start at the end
            }
        case .off:
            let current = resolvedCurrentIndex() ?? currentIndex
            if let current, current + 1 < queue.count {
                loadAndPlay(index: current + 1)
            } else {
                // End of queue: stop advancing but keep the queue and selection.
                isPlaying = false
                ticker?.cancel()
                updateNowPlaying()
            }
        }
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
            Task { @MainActor [weak self] in self?.stop() }
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
        currentCatalogInfo = nil   // resolved fresh for the new track
        let track = queue[index]
        isLoading = true
        errorMessage = nil

        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                guard let source = self.registry.source(for: track.sourceID) else {
                    throw FileSourceError.notConnected
                }
                // Use a pre-downloaded copy if we prefetched this track; otherwise
                // fetch it now (downloading from SMB).
                let sourceURL: URL
                if let prefetchedResource = self.prefetched[track.id] {
                    self.prefetched[track.id] = nil   // ownership transfers to playback
                    sourceURL = prefetchedResource.url
                } else if let cached = self.takeRecentlyPlayed(track.id) {
                    sourceURL = cached.url             // replayed from cache — no re-download
                } else {
                    sourceURL = try await source.fileURL(forPath: track.path)
                }
                try Task.checkCancellation()
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
                try Task.checkCancellation()
                if Task.isCancelled { playable.cleanup(); source.releaseTemporaryURL(sourceURL); return }
                self.startPlayback(playable: playable, sourceURL: sourceURL, track: track, sourceID: source.id, autoPlay: true)
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
            // Fully stopped: let audio-CD detection resume touching the drive.
            registry.setCDWatchSuspended(false)
        }
    }

    /// Moves the playhead to another queue entry without starting playback.
    private func selectTrack(at index: Int) {
        guard queue.indices.contains(index) else { return }
        loadTask?.cancel()
        tearDownPlayback(keepQueue: true)
        currentIndex = index
        currentCatalogInfo = nil
        isLoading = false
        updateNowPlaying()
    }

    private func startPlayback(playable: PlayableAudio, sourceURL: URL, track: Track, sourceID: String, autoPlay: Bool = true) {
        cleanupTemp()
        let isCD = registry.source(for: sourceID)?.kind == .audioCD
        // Suspend the audio-CD detection poll BEFORE we touch the disc (the
        // header read below, then streaming): probing the drive concurrently
        // with reads ejects the disc.
        if isCD { registry.setCDWatchSuspended(true) }
        do {
            // Match the hardware (USB DAC) to the file's native sample rate so the
            // system performs no resampling — bit-perfect output for the amp.
            applyPreferredHardwareFormat(for: playable.url)

            let newPlayer = try AVAudioPlayer(contentsOf: playable.url)
            newPlayer.delegate = self
            newPlayer.volume = 1.0       // unity gain; leave level control to the DAC/amp
            newPlayer.enableRate = false // no time-stretch/rate resampling in the path
            newPlayer.prepareToPlay()
            player = newPlayer
            duration = newPlayer.duration
            currentTime = 0
            isLoading = false
            activeResource = (sourceID, sourceURL, playable.temporaryURL, track.id)
            if autoPlay {
                newPlayer.play()
                isPlaying = true
                startTicker()
            } else {
                isPlaying = false
            }
            recordHistory(track)
            updateTrackSampleRate(trackID: track.id, sampleRate: newPlayer.format.sampleRate)
            updateNowPlaying()
            // Skip metadata for audio CDs: CDDA tracks carry no embedded tags or
            // art (so the lookup finds nothing), and reading the file for tags
            // would seek against AVAudioPlayer streaming the same track off the
            // disc — needless drive contention during playback.
            if !isCD {
                loadMetadata(for: playable.url, trackID: track.id)
            }
            prefetchUpcoming()   // get the next track(s) ready while this one plays
        } catch {
            playable.cleanup()
            registry.source(for: sourceID)?.releaseTemporaryURL(sourceURL)
            isLoading = false
            errorMessage = "Couldn't play \(track.title): \(error.localizedDescription)"
        }
    }

    /// Requests that the audio hardware run at `url`'s native sample rate (and
    /// channel count), avoiding sample-rate conversion on the way to a USB DAC.
    private func applyPreferredHardwareFormat(for url: URL) {
        #if os(iOS)
        guard let file = try? AVAudioFile(forReading: url) else { return }
        let format = file.fileFormat
        let session = AVAudioSession.sharedInstance()
        try? session.setPreferredSampleRate(format.sampleRate)
        let channels = Int(format.channelCount)
        if channels > 0 {
            try? session.setPreferredOutputNumberOfChannels(min(channels, session.maximumOutputNumberOfChannels))
        }
        try? session.setActive(true)
        #endif
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
            // Keep the downloaded source file for fast replay (History / back),
            // instead of releasing it right away. Decoder temp files are transient.
            retainRecentlyPlayed(trackID: active.trackID, sourceID: active.sourceID, url: active.sourceURL)
            if let decoded = active.decodedTempURL {
                try? FileManager.default.removeItem(at: decoded)
            }
        }
        activeResource = nil
    }

    /// Adds a just-played file to the recently-played cache, evicting the oldest
    /// (and deleting its temp) once the cap is exceeded.
    private func retainRecentlyPlayed(trackID: String, sourceID: String, url: URL) {
        recentlyPlayedOrder.removeAll { $0 == trackID }
        recentlyPlayed[trackID] = (sourceID, url)
        recentlyPlayedOrder.append(trackID)
        while recentlyPlayedOrder.count > recentlyPlayedCap {
            let evicted = recentlyPlayedOrder.removeFirst()
            if let resource = recentlyPlayed.removeValue(forKey: evicted) {
                registry.source(for: resource.sourceID)?.releaseTemporaryURL(resource.url)
            }
        }
    }

    /// Removes and returns a cached recently-played file, if present (ownership
    /// transfers back to active playback).
    private func takeRecentlyPlayed(_ trackID: String) -> (sourceID: String, url: URL)? {
        recentlyPlayedOrder.removeAll { $0 == trackID }
        return recentlyPlayed.removeValue(forKey: trackID)
    }

    private func clearRecentlyPlayed() {
        for resource in recentlyPlayed.values {
            registry.source(for: resource.sourceID)?.releaseTemporaryURL(resource.url)
        }
        recentlyPlayed.removeAll()
        recentlyPlayedOrder.removeAll()
    }

    // MARK: - Metadata

    /// Asynchronously enriches the current track with embedded title/artist/album.
    private func loadMetadata(for url: URL, trackID: String) {
        Task { [weak self] in
            let asset = AVURLAsset(url: url)
            guard let metadata = try? await asset.load(.commonMetadata) else { return }
            var artist: String?
            var album: String?
            var year: String?
            for item in metadata {
                guard let key = item.commonKey else { continue }
                let value = try? await item.load(.stringValue)
                switch key {
                case .commonKeyArtist: artist = value
                case .commonKeyAlbumName: album = value
                case .commonKeyCreationDate: year = Self.releaseYear(from: value)
                default: break
                }
            }
            let sampleRate = await AudioFormatReader.readSampleRate(from: url)
            // AVFoundation doesn't expose FLAC Vorbis comments, so read them
            // directly (this is a FLAC library). Fills artist/album/year/genre
            // the common-metadata pass missed.
            var genre: String?
            let flac = FlacTags.read(from: url)
            if !flac.isEmpty {
                if artist == nil { artist = flac["ARTIST"] ?? flac["ALBUMARTIST"] ?? flac["ALBUM ARTIST"] }
                if album == nil { album = flac["ALBUM"] }
                if year == nil { year = Self.releaseYear(from: flac["DATE"] ?? flac["YEAR"] ?? flac["ORIGINALDATE"]) }
                genre = flac["GENRE"]
            }
            // First pass: apply the file's embedded tags and start artwork resolution.
            let lookup: (artist: String?, album: String?)? = await MainActor.run {
                guard let self,
                      let idx = self.queue.firstIndex(where: { $0.id == trackID }) else { return nil }
                var track = self.queue[idx]
                if let artist { track.artist = artist }
                if let album { track.album = album }
                if let year { track.year = year }
                if let genre, track.genre == nil { track.genre = genre }
                if let sampleRate, track.sampleRate == nil { track.sampleRate = sampleRate }
                // The file-name-derived title is kept; embedded title is only a fallback.
                var updated = self.queue
                updated[idx] = track
                self.queue = updated
                if self.currentIndex == idx { self.updateNowPlaying() }
                // Fetch album art (embedded → folder cover → MusicKit → iTunes) for this track.
                self.artwork.resolve(track: track, fileURL: url, folderURL: url.deletingLastPathComponent())
                return (track.artist, track.album)
            }

            // Second pass: enrich from the Apple Music Catalog (MusicKit) and the
            // file's embedded lyrics, in parallel. This fills release year/genre
            // for untagged files and powers the full details panel (player) and
            // details section (remote).
            guard let lookup else { return }
            async let lyricsTask = EmbeddedLyrics.read(from: url)
            // Apple Music (MusicKit) first; if it can't (e.g. no developer token),
            // fall back to the free iTunes Search API so the details still fill.
            var catalog = MusicKitCatalog.isSupported
                ? await MusicKitCatalog.album(artist: lookup.artist, album: lookup.album)
                : nil
            if catalog == nil {
                catalog = await ITunesCatalog.album(artist: lookup.artist, album: lookup.album)
            }
            let lyrics = await lyricsTask
            var info = catalog ?? MusicKitCatalog.AlbumInfo()
            info.lyrics = lyrics
            // Fall back to the file's own tags so the details panel still shows
            // album / artist / year even when MusicKit isn't configured or finds
            // nothing.
            if info.albumTitle == nil { info.albumTitle = album }
            if info.artistName == nil { info.artistName = artist }
            if info.genres.isEmpty, let genre { info.genres = [genre] }
            if info.releaseDate == nil, info.yearText == nil { info.yearText = year }
            guard info.hasDisplayableDetails else { return }
            await MainActor.run {
                guard let self,
                      let idx = self.queue.firstIndex(where: { $0.id == trackID }) else { return }
                var track = self.queue[idx]
                var changed = false
                if track.year == nil, let y = info.year { track.year = y; changed = true }
                if track.genre == nil, let g = info.genre { track.genre = g; changed = true }
                if changed {
                    var updated = self.queue
                    updated[idx] = track
                    self.queue = updated
                }
                // Expose the full details for the current track (drives the
                // player's detail panel and the remote's details section).
                if self.currentIndex == idx {
                    self.currentCatalogInfo = info
                    self.updateNowPlaying()
                }
            }
        }
    }

    /// Pulls a 4-digit release year out of a metadata date string such as
    /// "1986", "2019-05-01", or "2004-01-01T00:00:00Z".
    static func releaseYear(from value: String?) -> String? {
        guard let value,
              let match = value.range(of: "(19|20)\\d{2}", options: .regularExpression)
        else { return nil }
        return String(value[match])
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

    // MARK: - Background reachability (screen off, paused)

    /// Watches app foreground/background transitions so the player can stay
    /// remote-controllable with the screen off. While playing, the `audio`
    /// background mode already keeps the app alive; the gap this covers is
    /// "backgrounded + paused/idle", where iOS would otherwise suspend the
    /// process and drop the remote's network link.
    private func observeAppLifecycle() {
        #if os(iOS)
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                           object: nil, queue: .main) { [weak self] _ in
            Self.runOnMainActor {
                guard let self else { return }
                self.isInBackground = true
                // Re-assert the audio session so active playback keeps going
                // with the screen off, exactly like the Music app.
                if self.isPlaying {
                    try? AVAudioSession.sharedInstance().setActive(true)
                }
                self.updateBackgroundKeepAlive()
            }
        }
        center.addObserver(forName: UIApplication.willEnterForegroundNotification,
                           object: nil, queue: .main) { [weak self] _ in
            Self.runOnMainActor {
                self?.isInBackground = false
                self?.updateBackgroundKeepAlive()
            }
        }
        #endif
    }

    /// Starts the inaudible keep-alive stream only when it's needed — the app is
    /// in the background, the feature is enabled, and real audio isn't already
    /// playing (which keeps the app alive on its own) — and stops it otherwise.
    private func updateBackgroundKeepAlive() {
        #if os(iOS)
        if backgroundRemoteEnabled && isInBackground && !isPlaying {
            keepAlive.start()
        } else {
            keepAlive.stop()
        }
        #endif
    }

    // MARK: - Audio session events (interruptions, route, reset)

    /// Whether playback was interrupted by the system (a phone call, Siri,
    /// another audio app) while it was playing, so it can be resumed when the
    /// interruption ends — the behavior users expect from the Music app.
    private var wasPlayingBeforeInterruption = false

    private func observeAudioSessionEvents() {
        #if os(iOS)
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        center.addObserver(forName: AVAudioSession.interruptionNotification,
                           object: session, queue: .main) { [weak self] note in
            Self.runOnMainActor { self?.handleInterruption(note) }
        }
        center.addObserver(forName: AVAudioSession.routeChangeNotification,
                           object: session, queue: .main) { [weak self] note in
            Self.runOnMainActor { self?.handleRouteChange(note) }
        }
        center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                           object: session, queue: .main) { [weak self] _ in
            Self.runOnMainActor { self?.handleMediaServicesReset() }
        }
        #endif
    }

    #if os(iOS)
    private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            // The system has already paused our audio; mirror that in our state
            // and remember we should resume when the interruption ends.
            wasPlayingBeforeInterruption = isPlaying
            if isPlaying {
                player?.pause()
                isPlaying = false
                updateNowPlaying()
            }
        case .ended:
            let options: AVAudioSession.InterruptionOptions
            if let rawOpts = info[AVAudioSessionInterruptionOptionKey] as? UInt {
                options = AVAudioSession.InterruptionOptions(rawValue: rawOpts)
            } else {
                options = []
            }
            if options.contains(.shouldResume) && wasPlayingBeforeInterruption {
                try? AVAudioSession.sharedInstance().setActive(true)
                resumePlayback()
            }
            wasPlayingBeforeInterruption = false
        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
        // Headphones/Bluetooth device removed: pause instead of suddenly
        // blasting the built-in speaker — matches the Music app.
        if reason == .oldDeviceUnavailable, isPlaying {
            pausePlayback()
        }
    }

    private func handleMediaServicesReset() {
        // The audio server crashed and restarted; every audio object is now
        // invalid. Rebuild the session and player and resume where we were.
        let resumeIndex = currentIndex
        let wasPlaying = isPlaying
        player?.delegate = nil
        player?.stop()
        player = nil
        configureAudioSession()
        if wasPlaying, let i = resumeIndex {
            loadAndPlay(index: i)
        }
    }
    #endif

    // MARK: - Remote commands & Now Playing

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Self.runOnMainActor { self?.togglePlayPause() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Self.runOnMainActor { self?.togglePlayPause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Self.runOnMainActor { self?.togglePlayPause() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Self.runOnMainActor { self?.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            var result = MPRemoteCommandHandlerStatus.commandFailed
            Self.runOnMainActor { [weak self] in
                guard let self, self.canGoPrevious else { return }
                self.previous()
                result = .success
            }
            return result
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Self.runOnMainActor { self?.seek(to: event.positionTime) }
            return .success
        }
    }

    /// Runs work on the main actor without trapping when callbacks arrive off the main thread.
    private nonisolated static func runOnMainActor(_ action: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { action() }
        } else {
            DispatchQueue.main.sync {
                MainActor.assumeIsolated { action() }
            }
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
            self?.advanceAfterPlaybackEnded()
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in
            self?.errorMessage = error?.localizedDescription ?? "Playback decode error."
            self?.next()
        }
    }
}

#if os(iOS)
/// Keeps the app resident in the background — and therefore reachable by the
/// FWPlayer Remote — when it would otherwise be suspended.
///
/// Once the app is backgrounded with the screen off and nothing is actively
/// playing, iOS suspends the process within a few seconds, which tears down the
/// remote-control network listener. Playing an inaudible, looping buffer through
/// the app's already-active `.playback` audio session keeps iOS treating the app
/// as "playing audio", so it stays alive and the remote can start/stop playback
/// at any time without anyone touching the device. Real playback replaces this
/// stream (there's no need to run both), and it's torn down the moment the app
/// returns to the foreground.
final class BackgroundAudioKeepAlive {
    private var player: AVAudioPlayer?
    private var active = false

    func start() {
        guard !active else { return }
        active = true
        if player == nil { player = Self.makeSilentPlayer() }
        player?.numberOfLoops = -1
        player?.volume = 0
        if player?.isPlaying == false { player?.play() }
    }

    func stop() {
        guard active else { return }
        active = false
        player?.stop()
        // Keep the (cheap) player instance around for fast restarts.
        player?.currentTime = 0
    }

    private static func makeSilentPlayer() -> AVAudioPlayer? {
        guard let data = silentWAV(seconds: 1),
              let player = try? AVAudioPlayer(data: data) else { return nil }
        player.prepareToPlay()
        return player
    }

    /// Synthesizes a short mono 16-bit PCM WAV of pure silence in memory, so no
    /// audio asset needs to ship in the bundle.
    private static func silentWAV(seconds: Double) -> Data? {
        let sampleRate = 44_100
        let channels = 1
        let bitsPerSample = 16
        let frameCount = max(1, Int(Double(sampleRate) * seconds))
        let dataSize = frameCount * channels * bitsPerSample / 8
        let byteRate = sampleRate * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8

        var d = Data()
        func appendLE32(_ v: Int) { var x = UInt32(truncatingIfNeeded: v).littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func appendLE16(_ v: Int) { var x = UInt16(truncatingIfNeeded: v).littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }

        d.append(contentsOf: Array("RIFF".utf8))
        appendLE32(36 + dataSize)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8))
        appendLE32(16)                 // PCM fmt chunk size
        appendLE16(1)                  // audio format = PCM
        appendLE16(channels)
        appendLE32(sampleRate)
        appendLE32(byteRate)
        appendLE16(blockAlign)
        appendLE16(bitsPerSample)
        d.append(contentsOf: Array("data".utf8))
        appendLE32(dataSize)
        d.append(Data(count: dataSize)) // silence
        return d
    }
}
#endif
