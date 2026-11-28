import Foundation

/// The iTunes Search API's album search, used for covers and album details.
enum ITunesSearch {
    /// Characters left as they are in a query value: everything a query allows except
    /// those that would end the value or change it ("&", "=", "#", and "+", which the
    /// server reads as a space). "Simon & Garfunkel" otherwise searches for "Simon ".
    static let queryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&=+#")
        return set
    }()

    /// The URL that searches albums for `term`, best match first.
    static func albumSearchURL(term: String, limit: Int = 1) -> URL? {
        guard let encoded = term.addingPercentEncoding(withAllowedCharacters: queryValueAllowed) else { return nil }
        return URL(string: "https://itunes.apple.com/search?media=music&entity=album&limit=\(limit)&term=\(encoded)")
    }
}
