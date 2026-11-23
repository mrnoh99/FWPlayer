import Foundation
import SwiftUI

/// Owns the user's playlists and their persistence. All mutations write through
/// to `PlaylistStore` so changes survive relaunches.
@MainActor
final class PlaylistManager: ObservableObject {
    @Published private(set) var playlists: [Playlist] = []

    private let store = PlaylistStore()

    /// The built-in Favorites playlist: always kept first and never deletable.
    static let favoritesID = UUID(uuidString: "FA000000-0000-0000-0000-000000000001")!
    static let favoritesName = "Favorites"

    /// The built-in Played playlist: every track you've played, oldest first
    /// (most recent last). Always kept second and never deletable or renamable.
    static let playedID = UUID(uuidString: "FA000000-0000-0000-0000-000000000002")!
    static let playedName = "Played"
    /// Most entries kept in Played; the oldest are dropped beyond this.
    static let playedLimit = 1000

    static func isBuiltIn(_ id: UUID) -> Bool { id == favoritesID || id == playedID }

    func load() {
        playlists = store.load()
        ensureFavoritesFirst()
        ensurePlayedSecond()
        migratePlayedToNewestFirst()
    }

    private static let playedNewestFirstKey = "playedNewestFirst"

    /// Played used to be stored oldest first; it is now newest first. Flip a list saved the
    /// old way, once.
    private func migratePlayedToNewestFirst() {
        guard !UserDefaults.standard.bool(forKey: Self.playedNewestFirstKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.playedNewestFirstKey)
        guard let index = playlists.firstIndex(where: { $0.id == Self.playedID }),
              playlists[index].entries.count > 1 else { return }
        playlists[index].entries.reverse()
        persist()
    }

    /// Guarantees a Played playlist exists and sits right after Favorites.
    private func ensurePlayedSecond() {
        let target = min(1, playlists.count)
        if let index = playlists.firstIndex(where: { $0.id == Self.playedID }) {
            if index != target {
                let played = playlists.remove(at: index)
                playlists.insert(played, at: min(1, playlists.count))
                persist()
            }
        } else {
            playlists.insert(Playlist(id: Self.playedID, name: Self.playedName), at: target)
            persist()
        }
    }

    /// Records a track in Played, newest first: moved to the top if it was already there.
    func recordPlayed(_ track: Track) {
        guard let index = playlists.firstIndex(where: { $0.id == Self.playedID }) else { return }
        let entry = PlaylistEntry(track: track)
        playlists[index].entries.removeAll { $0.id == entry.id }
        playlists[index].entries.insert(entry, at: 0)
        let excess = playlists[index].entries.count - Self.playedLimit
        if excess > 0 { playlists[index].entries.removeLast(excess) }
        persist()
    }

    /// Guarantees a Favorites playlist exists and is the first entry.
    private func ensureFavoritesFirst() {
        if let index = playlists.firstIndex(where: { $0.id == Self.favoritesID }) {
            if index != 0 {
                let favorites = playlists.remove(at: index)
                playlists.insert(favorites, at: 0)
                persist()
            }
        } else {
            playlists.insert(Playlist(id: Self.favoritesID, name: Self.favoritesName), at: 0)
            persist()
        }
    }

    var favorites: Playlist? { playlist(for: Self.favoritesID) }

    func isFavorite(_ track: Track) -> Bool { contains(track, in: Self.favoritesID) }

    /// Adds/removes the track from Favorites. Returns whether it's now a favorite.
    @discardableResult
    func toggleFavorite(_ track: Track) -> Bool {
        if isFavorite(track) {
            remove(track, from: Self.favoritesID)
            return false
        }
        add(track, to: Self.favoritesID)
        return true
    }

    func playlist(for id: UUID) -> Playlist? {
        playlists.first { $0.id == id }
    }

    @discardableResult
    func create(name: String) -> Playlist {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let playlist = Playlist(name: trimmed.isEmpty ? "New Playlist" : trimmed)
        playlists.append(playlist)
        persist()
        return playlist
    }

    func rename(_ id: UUID, to name: String) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, id != Self.playedID else { return }
        playlists[index].name = trimmed
        persist()
    }

    func delete(_ id: UUID) {
        guard !Self.isBuiltIn(id) else { return }   // Favorites and Played can't be deleted
        playlists.removeAll { $0.id == id }
        persist()
    }

    /// Appends a track, skipping it if the same file is already in the playlist.
    /// Returns whether the track was added.
    @discardableResult
    func add(_ track: Track, to id: UUID) -> Bool {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return false }
        let entry = PlaylistEntry(track: track)
        guard !playlists[index].entries.contains(where: { $0.id == entry.id }) else { return false }
        playlists[index].entries.append(entry)
        persist()
        return true
    }

    func remove(_ track: Track, from id: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        let entryID = PlaylistEntry(track: track).id
        playlists[index].entries.removeAll { $0.id == entryID }
        persist()
    }

    func contains(_ track: Track, in id: UUID) -> Bool {
        guard let playlist = playlist(for: id) else { return false }
        let entryID = PlaylistEntry(track: track).id
        return playlist.entries.contains { $0.id == entryID }
    }

    func removeEntries(at offsets: IndexSet, from id: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[index].entries.remove(atOffsets: offsets)
        persist()
    }

    func moveEntries(from offsets: IndexSet, to destination: Int, in id: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[index].entries.move(fromOffsets: offsets, toOffset: destination)
        persist()
    }

    private func persist() {
        store.save(playlists)
    }
}
