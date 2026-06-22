import Foundation
#if canImport(MusicKit)
import MusicKit
#endif

/// Apple Music **Catalog** lookup for album artwork and metadata.
///
/// This is the *primary* online source (iTunes Search is the backup in
/// `AlbumArtwork.online`). Catalog reads use the framework's automatically
/// managed developer token, so an Apple Music *subscription* is not required —
/// but the user must grant authorization once, and the app must be configured
/// with the MusicKit capability in the Apple Developer portal. When MusicKit is
/// unavailable, unauthorized, or returns nothing, every entry point returns
/// `nil` so the caller can fall back to iTunes Search.
enum MusicKitCatalog {
    /// Album info resolved from the catalog. Carries every field we surface in
    /// the player's detail view and forward to the remote.
    struct AlbumInfo: Equatable {
        var albumTitle: String? = nil
        var artistName: String? = nil
        var genres: [String] = []
        var releaseDate: Date? = nil
        /// An explicit year string (e.g. from the file's tags) used when there's
        /// no full `releaseDate` from the catalog.
        var yearText: String? = nil
        var trackCount: Int? = nil
        var recordLabel: String? = nil
        /// "Explicit" / "Clean" when rated.
        var contentRating: String? = nil
        /// Editorial blurb (Apple's album description), when present.
        var editorialNotes: String? = nil
        var copyright: String? = nil
        var artworkURL: URL? = nil
        /// Lyrics embedded in the audio file (MusicKit doesn't expose catalog
        /// lyrics publicly), shown in the details when present.
        var lyrics: String? = nil
        /// Where the metadata came from: "Apple Music", "iTunes", or "file tags".
        var source: String = "file tags"

        /// Four-digit release year, from `releaseDate` or the explicit `yearText`.
        var year: String? {
            if let releaseDate {
                return String(Calendar.current.component(.year, from: releaseDate))
            }
            return yearText
        }
        /// Primary genre.
        var genre: String? { genres.first }

        /// Whether there's anything worth showing in a details panel.
        var hasDisplayableDetails: Bool {
            albumTitle != nil || artistName != nil || !genres.isEmpty || releaseDate != nil
                || yearText != nil || trackCount != nil || recordLabel != nil || contentRating != nil
                || editorialNotes != nil || copyright != nil || lyrics != nil
        }
    }

    /// Whether MusicKit is compiled in and the OS is new enough to use it.
    static var isSupported: Bool {
        #if canImport(MusicKit)
        if #available(iOS 15.0, macCatalyst 15.0, *) { return true }
        #endif
        return false
    }

    /// Downloads album artwork as JPEG/PNG data, sized for `maxDimension`.
    /// Returns `nil` if MusicKit can't satisfy the request (caller falls back).
    static func artwork(artist: String?, album: String?,
                        maxDimension: Int, session: URLSession) async -> Data? {
        guard let info = await Self.album(artist: artist, album: album),
              let url = info.artworkURL else { return nil }
        let sized = artworkURL(url, side: maxDimension) ?? url
        guard let (data, _) = try? await session.data(from: sized) else { return nil }
        return data
    }

    /// Searches the catalog for an album and returns its artwork URL, release
    /// year, and primary genre. `nil` when unsupported/unauthorized/not found.
    static func album(artist: String?, album: String?) async -> AlbumInfo? {
        #if canImport(MusicKit)
        if #available(iOS 15.0, macCatalyst 15.0, *) {
            return await catalogAlbum(artist: artist, album: album)
        }
        #endif
        print("[MusicKit] unavailable on this build / OS")
        return nil
    }

    #if canImport(MusicKit)
    @available(iOS 15.0, macCatalyst 15.0, *)
    private static func catalogAlbum(artist: String?, album: String?) async -> AlbumInfo? {
        guard let album, !album.isEmpty else {
            print("[MusicKit] skip — no album tag to search")
            return nil
        }
        guard await isAuthorized() else {
            print("[MusicKit] not authorized (status=\(MusicAuthorization.currentStatus))")
            return nil
        }

        let term = searchTerm(artist: artist, album: album)
        var request = MusicCatalogSearchRequest(term: term, types: [Album.self])
        request.limit = 1
        do {
            let response = try await request.response()
            guard let match = response.albums.first else {
                print("[MusicKit] no catalog match for \"\(term)\"")
                return nil
            }
            print("[MusicKit] matched \"\(match.title)\" — \(match.artistName)")
            return AlbumInfo(
                albumTitle: match.title,
                artistName: match.artistName,
                genres: match.genreNames,
                releaseDate: match.releaseDate,
                trackCount: match.trackCount,
                recordLabel: match.recordLabelName,
                contentRating: contentRatingText(match.contentRating),
                editorialNotes: match.editorialNotes?.standard ?? match.editorialNotes?.short,
                copyright: match.copyright,
                artworkURL: match.artwork?.url(width: 1200, height: 1200),
                source: "Apple Music"
            )
        } catch {
            // Most commonly a missing developer token (the app/App ID isn't set up
            // with the MusicKit capability) even when the user has authorized.
            print("[MusicKit] catalog request failed for \"\(term)\": \(error)")
            return nil
        }
    }

    @available(iOS 15.0, macCatalyst 15.0, *)
    private static func contentRatingText(_ rating: ContentRating?) -> String? {
        switch rating {
        case .clean: return "Clean"
        case .explicit: return "Explicit"
        default: return nil
        }
    }

    /// Resolves authorization without re-prompting: requests access only the
    /// first time (status `.notDetermined`); afterwards it just reads the
    /// already-decided status. No prompt is ever shown more than once.
    ///
    /// Requesting access without an `NSAppleMusicUsageDescription` in Info.plist
    /// is a hard crash, so we only prompt when that key is present — otherwise we
    /// quietly decline and the caller falls back to iTunes Search.
    @available(iOS 15.0, macCatalyst 15.0, *)
    private static func isAuthorized() async -> Bool {
        switch MusicAuthorization.currentStatus {
        case .authorized: return true
        case .notDetermined:
            guard hasUsageDescription else { return false }
            return await MusicAuthorization.request() == .authorized
        default: return false   // denied / restricted
        }
    }
    #endif

    /// Whether Info.plist carries the privacy string required before prompting.
    private static var hasUsageDescription: Bool {
        let value = Bundle.main.object(forInfoDictionaryKey: "NSAppleMusicUsageDescription") as? String
        return !(value ?? "").isEmpty
    }

    /// Builds a catalog search term, stripping edition/format clutter from the
    /// album title so the search matches (e.g. "Thriller 25 (Super Deluxe Edition
    /// 2018)" → "Thriller 25 Michael Jackson", "… (MFSL LP)" → "…").
    static func searchTerm(artist: String?, album: String) -> String {
        var a = album.replacingOccurrences(
            of: "[\\(\\[][^\\)\\]]*[\\)\\]]", with: "", options: .regularExpression)
        a = a.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if a.isEmpty { a = album }   // never strip down to nothing
        if let artist, !artist.isEmpty { return a + " " + artist }
        return a
    }

    /// Rewrites an Apple artwork template/URL to request a square render of the
    /// given pixel side (Apple URLs embed `{w}x{h}` or a fixed `NNNxNNNbb`).
    private static func artworkURL(_ url: URL, side: Int) -> URL? {
        var s = url.absoluteString
        if s.contains("{w}") || s.contains("{h}") {
            s = s.replacingOccurrences(of: "{w}", with: "\(side)")
                 .replacingOccurrences(of: "{h}", with: "\(side)")
                 .replacingOccurrences(of: "{f}", with: "jpg")
        }
        return URL(string: s)
    }
}

/// Album metadata from the free iTunes Search API — no developer token or
/// MusicKit capability required. Used as the fallback when MusicKit can't get a
/// token (`.developerTokenRequestFailed`), so the details panel still fills with
/// genre, release date, track count, etc.
enum ITunesCatalog {
    static func album(artist: String?, album: String?) async -> MusicKitCatalog.AlbumInfo? {
        guard let album, !album.isEmpty else { return nil }
        let term = MusicKitCatalog.searchTerm(artist: artist, album: album)
        guard let encoded = term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://itunes.apple.com/search?media=music&entity=album&limit=1&term=\(encoded)")
        else { return nil }

        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]],
              let first = results.first else {
            print("[iTunes] request failed for \"\(term)\"")
            return nil
        }

        var info = MusicKitCatalog.AlbumInfo()
        info.albumTitle = first["collectionName"] as? String
        info.artistName = first["artistName"] as? String
        if let genre = first["primaryGenreName"] as? String, !genre.isEmpty { info.genres = [genre] }
        if let releaseStr = first["releaseDate"] as? String {
            info.releaseDate = ISO8601DateFormatter().date(from: releaseStr)
        }
        info.trackCount = first["trackCount"] as? Int
        info.copyright = first["copyright"] as? String
        if let art = first["artworkUrl100"] as? String {
            info.artworkURL = URL(string: art.replacingOccurrences(of: "100x100bb", with: "1200x1200bb"))
        }
        info.source = "iTunes"

        guard info.hasDisplayableDetails else {
            print("[iTunes] no usable fields for \"\(term)\"")
            return nil
        }
        print("[iTunes] matched \"\(info.albumTitle ?? term)\"")
        return info
    }
}
