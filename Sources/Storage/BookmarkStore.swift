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
    ///
    /// The picker's URL only carries its sandbox extension while access has been
    /// started, and a bookmark captures that extension: creating it *without*
    /// `startAccessingSecurityScopedResource()` gave a bookmark that still resolved
    /// after a relaunch (so the folder and its cached listing showed up) but granted
    /// no access, and every file in it failed to play.
    static func makeBookmark(for url: URL) throws -> Data {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        #if targetEnvironment(macCatalyst)
        // A sandboxed Mac app needs an explicit security-scoped bookmark.
        return try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        #else
        return try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        #endif
    }

    /// Resolves a stored bookmark back into a URL, reporting whether it is stale.
    static func resolve(_ data: Data) throws -> (url: URL, isStale: Bool) {
        var isStale = false
        #if targetEnvironment(macCatalyst)
        // Newer bookmarks are security-scoped; older ones were plain.
        if let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil,
                              bookmarkDataIsStale: &isStale) {
            return (url, isStale)
        }
        #endif
        let url = try URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale)
        return (url, isStale)
    }
}
