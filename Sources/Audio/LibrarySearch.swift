import Foundation

/// Matching for the library search: folder and file names are compared after folding case,
/// accents and Unicode form, so "eagles", "Éagles" and a decomposed Hangul file name typed on
/// the iPad all match what you'd expect.
enum LibrarySearch {
    /// Lower-cased, accent-folded, canonically composed text.
    static func normalize(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// The words of a query, normalised. Empty for a blank query.
    static func terms(from query: String) -> [String] {
        normalize(query)
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    /// nil when the item doesn't match, otherwise a score (higher is better).
    ///
    /// An item matches when every word appears somewhere in its path **and** at least one word
    /// is in its own name. That finds "Eagles Hotel California" as the track
    /// `Eagles/…/01-Hotel California` without every track under a folder named "Eagles"
    /// also matching a search for "eagles".
    static func score(name: String, path: String, isFolder: Bool, terms: [String]) -> Int? {
        guard !terms.isEmpty else { return nil }
        let n = normalize(name)
        let inName = terms.filter { n.contains($0) }.count
        guard inName > 0 else { return nil }                       // cheap rejection first
        let p = normalize(path)
        guard terms.allSatisfy({ p.contains($0) }) else { return nil }

        var score = inName * 100
        if inName == terms.count { score += 200 }
        if n == terms.joined(separator: " ") { score += 300 }      // exactly what was typed
        if let first = terms.first, n.hasPrefix(first) { score += 50 }
        if isFolder { score += 25 }                                // folders are the usual target
        score -= min(path.split(separator: "/").count, 20)         // shallower first
        return score
    }
}
