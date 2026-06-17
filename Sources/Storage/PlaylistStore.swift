import Foundation

/// Persists user playlists as JSON in UserDefaults.
struct PlaylistStore {
    private let defaultsKey = "fwplayer.playlists"
    private var defaults: UserDefaults { .standard }

    func load() -> [Playlist] {
        guard let data = defaults.data(forKey: defaultsKey),
              let playlists = try? JSONDecoder().decode([Playlist].self, from: data) else {
            return []
        }
        return playlists
    }

    func save(_ playlists: [Playlist]) {
        if let data = try? JSONEncoder().encode(playlists) {
            defaults.set(data, forKey: defaultsKey)
        }
    }
}
