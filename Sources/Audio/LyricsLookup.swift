import Foundation

/// Lyrics from LRCLIB (lrclib.net), a free lyrics database that needs no key, for
/// tracks whose files carry none. Only the track's title, artist, album and length
/// are sent.
enum LyricsLookup {
    /// One LRCLIB search result.
    struct Entry: Decodable, Equatable {
        var trackName: String?
        var artistName: String?
        var albumName: String?
        var duration: Double?
        var instrumental: Bool?
        var plainLyrics: String?
        var syncedLyrics: String?
    }

    /// What a lookup found.
    enum Outcome: Equatable {
        case lyrics(String)
        case instrumental
        case notFound
    }

    /// LRCLIB asks clients to identify themselves.
    static let userAgent = "FWPlayer (https://github.com/mrnoh99/FWPlayer)"

    /// The lyrics for a track, or nil if LRCLIB has none (or the track is instrumental,
    /// or the request failed).
    static func lyrics(title: String, artist: String?, album: String?, duration: Double?) async -> String? {
        let outcome = await lookUp(title: title, artist: artist, album: album, duration: duration)
        switch outcome {
        case .lyrics(let text):
            DiagnosticsLog.log("lyrics", "LRCLIB: found lyrics for \"\(title)\"")
            return text
        case .instrumental:
            DiagnosticsLog.log("lyrics", "LRCLIB: \"\(title)\" is an instrumental")
            return nil
        case .notFound:
            DiagnosticsLog.log("lyrics", "LRCLIB: no lyrics for \"\(title)\"")
            return nil
        }
    }

    static func lookUp(title: String, artist: String?, album: String?, duration: Double?) async -> Outcome {
        let artist = artist?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        // The app's titles come from file names ("05. Artist - Title"); the cleaned
        // title is tried first, then the title as it is.
        var titles = [searchTitle(title, artist: artist)]
        let original = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !titles.contains(original) { titles.append(original) }
        for candidate in titles where !candidate.isEmpty {
            guard let entries = await search(title: candidate, artist: artist), !entries.isEmpty else { continue }
            return outcome(of: best(entries, duration: duration))
        }
        return .notFound
    }

    // MARK: Network

    private static func search(title: String, artist: String?) async -> [Entry]? {
        var components = URLComponents(string: "https://lrclib.net/api/search")!
        if let artist {
            components.queryItems = [URLQueryItem(name: "track_name", value: title),
                                     URLQueryItem(name: "artist_name", value: artist)]
        } else {
            components.queryItems = [URLQueryItem(name: "q", value: title)]
        }
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else {
            DiagnosticsLog.log("lyrics", "LRCLIB: request failed for \"\(title)\"")
            return nil
        }
        return try? JSONDecoder().decode([Entry].self, from: data)
    }

    // MARK: Matching (pure)

    /// A file-name title made searchable: drops a leading track number ("05. ",
    /// "03 - ", "1-03 ") and a leading "Artist - " that repeats the artist.
    static func searchTitle(_ title: String, artist: String?) -> String {
        var text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = text.range(of: #"^\d{1,3}(?:[-.]\d{1,3})?\s*[.)\-–_]?\s+"#, options: .regularExpression) {
            let rest = String(text[range.upperBound...])
            if !rest.isEmpty { text = rest }
        }
        if let artist, !artist.isEmpty {
            for separator in [" - ", " – ", " — "] {
                let prefix = artist + separator
                if text.lowercased().hasPrefix(prefix.lowercased()) {
                    let rest = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                    if !rest.isEmpty { text = rest }
                    break
                }
            }
        }
        return text
    }

    /// The result to use: the one closest in length to the track (another edit of the
    /// same song can have a different length), preferring one with lyrics on a tie.
    /// Nil when every result is far from the track's length, i.e. likely another song.
    static func best(_ entries: [Entry], duration: Double?) -> Entry? {
        guard let duration, duration > 0 else {
            return entries.first { $0.hasLyrics } ?? entries.first
        }
        let ranked = entries.compactMap { entry -> (Entry, Double)? in
            guard let length = entry.duration else { return nil }
            return (entry, abs(length - duration))
        }
        .sorted { a, b in
            if abs(a.1 - b.1) > 2 { return a.1 < b.1 }
            return a.0.hasLyrics && !b.0.hasLyrics
        }
        guard let closest = ranked.first, closest.1 <= 30 else { return nil }
        return closest.0
    }

    static func outcome(of entry: Entry?) -> Outcome {
        guard let entry else { return .notFound }
        if entry.instrumental == true { return .instrumental }
        if let plain = entry.plainLyrics?.trimmingCharacters(in: .whitespacesAndNewlines), !plain.isEmpty {
            return .lyrics(plain)
        }
        if let synced = entry.syncedLyrics, let plain = plainText(fromSynced: synced) {
            return .lyrics(plain)
        }
        return .notFound
    }

    /// Plain text from LRC-style synced lyrics: timestamps and "[ar:…]"-style tags removed.
    static func plainText(fromSynced synced: String) -> String? {
        let lines = synced.components(separatedBy: .newlines).compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.range(of: #"^\[[a-zA-Z]+:.*\]$"#, options: .regularExpression) != nil { return nil }
            return trimmed.replacingOccurrences(of: #"^(\[\d+:\d+(?:[.:]\d+)?\]\s?)+"#, with: "",
                                                options: .regularExpression)
        }
        let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

extension LyricsLookup.Entry {
    var hasLyrics: Bool {
        instrumental != true && (plainLyrics?.isEmpty == false || syncedLyrics?.isEmpty == false)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
