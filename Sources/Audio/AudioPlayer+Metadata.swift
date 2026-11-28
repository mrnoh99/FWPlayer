import Foundation
import AVFoundation
import MediaPlayer
import Combine
#if os(iOS)
import UIKit
#endif

/// Album details, artwork and lyrics for the playing track (catalog lookups, file tags, LRCLIB).
extension AudioPlayer {
    // MARK: - Metadata

    /// Asynchronously enriches the current track with embedded title/artist/album.
    func loadMetadata(for url: URL, trackID: String) {
        Task { [weak self] in
            let asset = AVURLAsset(url: url)
            // AVFoundation can't open every format (e.g. DSD); carry on with the
            // tags we read ourselves below.
            let metadata = (try? await asset.load(.commonMetadata)) ?? []
            var artist: String?
            var album: String?
            var year: String?
            var composer: String?
            var work: String?
            // Composer / work aren't in AVFoundation's common keys: read the ID3 / iTunes ones.
            let allMetadata = (try? await asset.load(.metadata)) ?? []
            for identifier in [AVMetadataIdentifier.id3MetadataComposer, .iTunesMetadataComposer] {
                if let item = AVMetadataItem.metadataItems(from: allMetadata, filteredByIdentifier: identifier).first,
                   let value = try? await item.load(.stringValue), !value.isEmpty {
                    composer = value
                    break
                }
            }
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
                if composer == nil { composer = flac["COMPOSER"] }
                work = flac["WORK"]
            }
            // DSD (DSF/DFF) files carry ID3v2 tags.
            let dsd = DSDTags.read(from: url)
            if !dsd.isEmpty {
                if artist == nil { artist = dsd["ARTIST"] ?? dsd["ALBUMARTIST"] }
                if album == nil { album = dsd["ALBUM"] }
                if year == nil { year = Self.releaseYear(from: dsd["DATE"]) }
                if genre == nil { genre = dsd["GENRE"] }
                if composer == nil { composer = dsd["COMPOSER"] }
                if work == nil { work = dsd["WORK"] }
            }
            // First pass: apply the file's embedded tags and start artwork resolution.
            let lookup: (artist: String?, album: String?)? = await MainActor.run {
                guard let self,
                      let idx = self.queueIndexOfPlaying(trackID) else { return nil }
                var track = self.queue[idx]
                if let artist { track.artist = artist }
                if let album { track.album = album }
                if let year { track.year = year }
                if let genre, track.genre == nil { track.genre = genre }
                if let composer, track.composer == nil { track.composer = composer }
                if let work, track.work == nil { track.work = work }
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
            guard lookup != nil, let self else { return }
            await self.publishDetails(trackID: trackID, artist: artist, album: album, genre: genre, year: year,
                                      lyrics: { await EmbeddedLyrics.read(from: url) })
        }
    }

    /// The one place album details are assembled, for every playback path (local file,
    /// share stream, download): looks the album up in the Apple Music / iTunes catalog,
    /// falls back to the file's own tags, adds the lyrics, and publishes the result for the
    /// player's details panel and the remote. Fills a track's missing year / genre too.
    func publishDetails(trackID: String, artist: String?, album: String?, genre: String?, year: String?,
                                lyrics: @escaping () async -> String?) async {
        let playing = queueIndexOfPlaying(trackID).map { queue[$0] }
        let length = playing?.duration ?? (currentTrack?.id == trackID && duration > 0 ? duration : nil)
        let online = onlineLyrics
        let cachedLyrics: LyricsLookup.Lyrics?? = online ? onlineLyricsCache[trackID] : nil
        async let lyricsTask = Self.resolveLyrics(embedded: lyrics, cached: cachedLyrics,
                                                  online: online, title: playing?.title,
                                                  artist: artist ?? playing?.artist,
                                                  album: album ?? playing?.album, duration: length)
        var catalog: MusicKitCatalog.AlbumInfo?
        let catalogKey = "\(artist ?? "")\u{1F}\(album ?? "")"
        if let cached = catalogCache[catalogKey] {
            catalog = cached
        } else if artist != nil || album != nil {
            // Apple Music (MusicKit) first; if it can't (e.g. no developer token),
            // fall back to the free iTunes Search API so the details still fill.
            catalog = MusicKitCatalog.isSupported ? await MusicKitCatalog.album(artist: artist, album: album) : nil
            if catalog == nil { catalog = await ITunesCatalog.album(artist: artist, album: album) }
            if let catalog {
                if catalogCache.count >= Self.metadataCacheLimit { catalogCache.removeAll() }
                catalogCache[catalogKey] = catalog
            }
        }
        var info = catalog ?? MusicKitCatalog.AlbumInfo()
        let resolved = await lyricsTask
        info.lyrics = resolved.lyrics?.plain
        info.syncedLyrics = resolved.lyrics?.synced
        if let outcome = resolved.online, outcome != .unavailable {      // a failed request is retried next time
            if onlineLyricsCache.count >= Self.metadataCacheLimit { onlineLyricsCache.removeAll() }
            onlineLyricsCache.updateValue(outcome.lyrics, forKey: trackID)
        }
        // The file's own tags keep the panel useful when the catalog finds nothing.
        if info.albumTitle == nil { info.albumTitle = album }
        if info.artistName == nil { info.artistName = artist }
        if info.genres.isEmpty, let genre { info.genres = [genre] }
        if info.releaseDate == nil, info.yearText == nil { info.yearText = year }
        guard info.hasDisplayableDetails,
              let idx = queueIndexOfPlaying(trackID) else { return }
        var track = queue[idx]
        var changed = false
        if track.year == nil, let y = info.year { track.year = y; changed = true }
        if track.genre == nil, let g = info.genre { track.genre = g; changed = true }
        if changed {
            var updated = queue
            updated[idx] = track
            queue = updated
        }
        if currentIndex == idx {
            currentCatalogInfo = info
            updateNowPlaying()
        }
    }

    /// The file's own lyrics, else LRCLIB's for the track (the details panel and the remote show them).
    /// `online` is LRCLIB's answer when it was asked this time (for caching); `cached` is an earlier
    /// answer for the track (a nil inside means LRCLIB has none).
    private nonisolated static func resolveLyrics(embedded: () async -> String?, cached: LyricsLookup.Lyrics??,
                                                  online: Bool, title: String?, artist: String?, album: String?,
                                                  duration: Double?) async -> (lyrics: LyricsLookup.Lyrics?,
                                                                                online: LyricsLookup.Outcome?) {
        if let own = await embedded(), let lyrics = LyricsLookup.lyrics(fromEmbedded: own) { return (lyrics, nil) }
        if let cached { return (cached, nil) }
        guard online, let title, !title.isEmpty else { return (nil, nil) }
        let outcome = await LyricsLookup.find(title: title, artist: artist, album: album, duration: duration)
        return (outcome.lyrics, outcome)
    }

    #if targetEnvironment(macCatalyst)
    /// Enriches a playing audio-CD track from the MusicBrainz disc lookup:
    /// resolved track title, plus album/artist/year for the queue, the details
    /// panel, and online (non-disc) artwork.
    func loadCDMetadata(trackID: String, sourceID: String) {
        guard let cd = registry.source(for: sourceID) as? CDAudioSource else { return }
        Task { [weak self] in
            let info = await cd.awaitDiscInfo()
            guard let self, let info, !info.isEmpty else { return }
            await MainActor.run {
                guard let idx = self.queueIndexOfPlaying(trackID) else { return }
                let old = self.queue[idx]
                // Track.title is immutable, so rebuild when the lookup resolved a
                // real title; otherwise just fill artist/album/year.
                var track: Track
                if let title = cd.title(forPath: old.path) {
                    track = Track(sourceID: old.sourceID, path: old.path, title: title)
                    track.duration = old.duration
                    track.sampleRate = old.sampleRate
                } else {
                    track = old
                }
                track.artist = info.artist
                track.album = info.album
                track.year = info.year
                var updated = self.queue
                updated[idx] = track
                self.queue = updated

                if self.currentIndex == idx {
                    var album = MusicKitCatalog.AlbumInfo()
                    album.albumTitle = info.album
                    album.artistName = info.artist
                    album.yearText = info.year
                    album.trackCount = info.trackTitles.isEmpty ? nil : info.trackTitles.count
                    album.source = "MusicBrainz"
                    self.currentCatalogInfo = album
                    self.updateNowPlaying()
                    self.artwork.resolveOnline(track: track)
                }
            }
        }
    }
    #endif

    /// Pulls a 4-digit release year out of a metadata date string such as
    /// "1986", "2019-05-01", or "2004-01-01T00:00:00Z".
    static func releaseYear(from value: String?) -> String? {
        guard let value,
              let match = value.range(of: "(19|20)\\d{2}", options: .regularExpression)
        else { return nil }
        return String(value[match])
    }

    func updateTrackSampleRate(trackID: String, sampleRate: Double) {
        guard sampleRate > 0,
              let idx = queueIndexOfPlaying(trackID) else { return }
        var updated = queue
        updated[idx].sampleRate = sampleRate
        queue = updated
    }
}
