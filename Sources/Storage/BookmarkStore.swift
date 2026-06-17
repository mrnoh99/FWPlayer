import Foundation

/// Persists security-scoped bookmarks for user-selected folders so access
/// survives app relaunches.
struct BookmarkStore {
    private let defaultsKey = "fwplayer.folderBookmarks"

    struct Entry: Codable {
        let id: String
        let displayName: String
        let bookmark: Data
    }

    private var defaults: UserDefaults { .standard }

    func load() -> [Entry] {
        guard let data = defaults.data(forKey: defaultsKey),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else {
            return []
        }
        return entries
    }

    private func save(_ entries: [Entry]) {
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: defaultsKey)
        }
    }

    func add(_ entry: Entry) {
        var entries = load().filter { $0.id != entry.id }
        entries.append(entry)
        save(entries)
    }

    func remove(id: String) {
        save(load().filter { $0.id != id })
    }

    /// Creates a security-scoped bookmark for a folder chosen by the user.
    static func makeBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// Resolves a stored bookmark back into a URL, reporting whether it is stale.
    static func resolve(_ data: Data) throws -> (url: URL, isStale: Bool) {
        var isStale = false
        let url = try URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale)
        return (url, isStale)
    }
}
