import XCTest
@testable import FWPlayerCore

/// Playlists, saved to a throwaway UserDefaults suite.
@MainActor
final class PlaylistManagerTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suiteName = "PlaylistManagerTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeManager() -> PlaylistManager {
        let manager = PlaylistManager(defaults: defaults)
        manager.load()
        return manager
    }

    private func track(_ name: String) -> Track {
        Track(sourceID: "local", path: "/\(name).flac", title: name)
    }

    private func titles(_ manager: PlaylistManager, _ id: UUID) -> [String] {
        manager.playlist(for: id)?.entries.map(\.title) ?? []
    }

    func testBuiltInPlaylistsComeFirstAndCantBeDeletedOrRenamed() {
        let manager = makeManager()
        XCTAssertEqual(manager.playlists.map(\.id), [PlaylistManager.favoritesID, PlaylistManager.playedID])
        manager.delete(PlaylistManager.favoritesID)
        manager.delete(PlaylistManager.playedID)
        manager.rename(PlaylistManager.playedID, to: "Mine")
        XCTAssertEqual(manager.playlists.count, 2)
        XCTAssertEqual(manager.playlist(for: PlaylistManager.playedID)?.name, PlaylistManager.playedName)
    }

    func testAddSkipsDuplicatesAndPlaylistsAreSaved() {
        let manager = makeManager()
        let mix = manager.create(name: "  Mix  ")
        XCTAssertEqual(mix.name, "Mix")
        XCTAssertTrue(manager.add(track("a"), to: mix.id))
        XCTAssertFalse(manager.add(track("a"), to: mix.id))
        XCTAssertTrue(manager.add(track("b"), to: mix.id))

        let reloaded = makeManager()
        XCTAssertEqual(titles(reloaded, mix.id), ["a", "b"])
    }

    func testFavoritesToggle() {
        let manager = makeManager()
        XCTAssertTrue(manager.toggleFavorite(track("a")))
        XCTAssertTrue(manager.isFavorite(track("a")))
        XCTAssertFalse(manager.toggleFavorite(track("a")))
        XCTAssertFalse(manager.isFavorite(track("a")))
    }

    func testPlayedIsNewestFirstWithoutRepeats() {
        let manager = makeManager()
        manager.recordPlayed(track("a"))
        manager.recordPlayed(track("b"))
        manager.recordPlayed(track("a"))
        XCTAssertEqual(titles(manager, PlaylistManager.playedID), ["a", "b"])
    }

    func testMoveAndRemoveEntries() {
        let manager = makeManager()
        let mix = manager.create(name: "Mix")
        for name in ["a", "b", "c"] { manager.add(track(name), to: mix.id) }
        manager.moveEntries(from: IndexSet([2]), to: 0, in: mix.id)
        XCTAssertEqual(titles(manager, mix.id), ["c", "a", "b"])
        manager.removeEntries(at: IndexSet([0, 2]), from: mix.id)
        XCTAssertEqual(titles(manager, mix.id), ["a"])
    }

    func testStalePositionsAreIgnoredInsteadOfTrapping() {
        // A remote showing an older list can send positions that are gone.
        let manager = makeManager()
        let mix = manager.create(name: "Mix")
        for name in ["a", "b"] { manager.add(track(name), to: mix.id) }
        manager.removeEntries(at: IndexSet([1, 5]), from: mix.id)
        manager.moveEntries(from: IndexSet([4]), to: 0, in: mix.id)
        manager.moveEntries(from: IndexSet([0]), to: 9, in: mix.id)
        XCTAssertEqual(titles(manager, mix.id), ["a", "b"])
    }
}
