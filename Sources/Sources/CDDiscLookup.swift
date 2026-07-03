import Foundation
import CryptoKit

#if targetEnvironment(macCatalyst)

/// Album/track metadata resolved for an inserted audio CD.
struct CDDiscInfo: Equatable {
    var album: String?
    var artist: String?
    var year: String?
    /// Track title keyed by 1-based track number.
    var trackTitles: [Int: String]
    /// MusicBrainz release id, usable for Cover Art Archive lookups.
    var releaseMBID: String?

    var isEmpty: Bool { album == nil && artist == nil && trackTitles.isEmpty }
}

/// Looks up an audio CD in the free MusicBrainz database from its table of
/// contents (the per-track sector offsets). CDDA discs carry no embedded tags,
/// so the disc's geometry is the only key we have; MusicBrainz indexes releases
/// by exactly this "disc ID".
enum CDDiscLookup {
    /// A polite, identifying User-Agent is required by the MusicBrainz API.
    private static let userAgent = "FWPlayer/1.0 ( https://github.com/mrnoh99/fwplayer )"

    /// - Parameters:
    ///   - firstTrack: usually 1.
    ///   - lastTrack: the number of audio tracks.
    ///   - offsets: 100-element array — index 0 is the lead-out offset, indices
    ///     1…lastTrack are each track's start sector (LBA + 150 pregap), rest 0.
    static func lookup(firstTrack: Int, lastTrack: Int, offsets: [Int]) async -> CDDiscInfo? {
        let discID = musicBrainzDiscID(firstTrack: firstTrack, lastTrack: lastTrack, offsets: offsets)

        // 1) Exact disc-ID match.
        if let info = await request(
            "https://musicbrainz.org/ws/2/discid/\(discID)?fmt=json&inc=recordings+artist-credits",
            trackCount: lastTrack) {
            return info
        }

        // 2) Fuzzy TOC match — more forgiving if the exact ID isn't in the
        //    database but a release with a matching layout is.
        var toc = "\(firstTrack)+\(lastTrack)+\(offsets[0])"
        for i in 1...lastTrack { toc += "+\(offsets[i])" }
        let fuzzy = "https://musicbrainz.org/ws/2/discid/-?toc=\(toc)&fmt=json&inc=recordings+artist-credits"
        return await request(fuzzy, trackCount: lastTrack)
    }

    // MARK: - Networking

    private static func request(_ urlString: String, trackCount: Int) async -> CDDiscInfo? {
        guard let url = URL(string: urlString) else { return nil }
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15

        guard let (data, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        guard let releases = root["releases"] as? [[String: Any]],
              let release = bestRelease(from: releases, trackCount: trackCount) else {
            return nil
        }
        return parse(release: release, trackCount: trackCount)
    }

    /// Prefer a release whose medium track count matches the disc.
    private static func bestRelease(from releases: [[String: Any]], trackCount: Int) -> [String: Any]? {
        for release in releases {
            if let media = release["media"] as? [[String: Any]],
               media.contains(where: { ($0["tracks"] as? [[String: Any]])?.count == trackCount }) {
                return release
            }
        }
        return releases.first
    }

    private static func parse(release: [String: Any], trackCount: Int) -> CDDiscInfo? {
        let album = release["title"] as? String
        let mbid = release["id"] as? String

        var artist: String?
        if let credits = release["artist-credit"] as? [[String: Any]] {
            let names = credits.compactMap { $0["name"] as? String }
            if !names.isEmpty { artist = names.joined() }
        }

        var year: String?
        if let date = release["date"] as? String, date.count >= 4 {
            year = String(date.prefix(4))
        }

        var titles: [Int: String] = [:]
        if let media = release["media"] as? [[String: Any]] {
            // The medium matching this disc (by track count), else the first.
            let medium = media.first { ($0["tracks"] as? [[String: Any]])?.count == trackCount } ?? media.first
            if let tracks = medium?["tracks"] as? [[String: Any]] {
                for track in tracks {
                    guard let title = track["title"] as? String else { continue }
                    let number = (track["position"] as? Int) ?? Int(track["number"] as? String ?? "")
                    if let number { titles[number] = title }
                }
            }
        }

        let info = CDDiscInfo(album: album, artist: artist, year: year, trackTitles: titles, releaseMBID: mbid)
        return info.isEmpty ? nil : info
    }

    // MARK: - MusicBrainz Disc ID

    /// Computes the MusicBrainz Disc ID: a SHA-1 over the fixed-width hex TOC,
    /// base64-encoded with a URL-safe alphabet (`+/=` → `._-`).
    private static func musicBrainzDiscID(firstTrack: Int, lastTrack: Int, offsets: [Int]) -> String {
        var s = String(format: "%02X%02X", UInt32(firstTrack), UInt32(lastTrack))
        for i in 0..<100 {
            let value = i < offsets.count ? offsets[i] : 0
            s += String(format: "%08X", UInt32(truncatingIfNeeded: value))
        }
        let digest = Insecure.SHA1.hash(data: Data(s.utf8))
        var b64 = Data(digest).base64EncodedString()
        b64 = b64.replacingOccurrences(of: "+", with: ".")
                 .replacingOccurrences(of: "/", with: "_")
                 .replacingOccurrences(of: "=", with: "-")
        return b64
    }
}

#endif
