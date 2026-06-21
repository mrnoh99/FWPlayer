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

        /// Four-digit release year derived from `releaseDate`.
        var year: String? {
            releaseDate.map { String(Calendar.current.component(.year, from: $0)) }
        }
        /// Primary genre.
        var genre: String? { genres.first }

        /// Whether there's anything worth showing in a details panel.
        var hasDisplayableDetails: Bool {
            albumTitle != nil || artistName != nil || !genres.isEmpty || releaseDate != nil
                || trackCount != nil || recordLabel != nil || contentRating != nil
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
        guard let info = await album(artist: artist, album: album),
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
        return nil
    }

    #if canImport(MusicKit)
    @available(iOS 15.0, macCatalyst 15.0, *)
    private static func catalogAlbum(artist: String?, album: String?) async -> AlbumInfo? {
        guard let album, !album.isEmpty else { return nil }
        guard await isAuthorized() else { return nil }

        var term = album
        if let artist, !artist.isEmpty { term += " " + artist }

        var request = MusicCatalogSearchRequest(term: term, types: [Album.self])
        request.limit = 1
        guard let response = try? await request.response(),
              let match = response.albums.first else { return nil }

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
            artworkURL: match.artwork?.url(width: 1200, height: 1200)
        )
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
    @available(iOS 15.0, macCatalyst 15.0, *)
    private static func isAuthorized() async -> Bool {
        switch MusicAuthorization.currentStatus {
        case .authorized: return true
        case .notDetermined: return await MusicAuthorization.request() == .authorized
        default: return false   // denied / restricted
        }
    }
    #endif

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
