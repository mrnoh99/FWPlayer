import Foundation

/// A persisted reference to a track within a playlist. Stores just enough to
/// resolve the file back to a playable URL through its `FileSource` later.
struct PlaylistEntry: Codable, Hashable, Identifiable {
    let sourceID: String
    let path: String
    let title: String

    var id: String { sourceID + "::" + path }

    init(sourceID: String, path: String, title: String) {
        self.sourceID = sourceID
        self.path = path
        self.title = title
    }

    init(track: Track) {
        self.init(sourceID: track.sourceID, path: track.path, title: track.title)
    }
}

/// A user-created, ordered collection of tracks.
struct Playlist: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var entries: [PlaylistEntry]

    init(id: UUID = UUID(), name: String, entries: [PlaylistEntry] = []) {
        self.id = id
        self.name = name
        self.entries = entries
    }

    var tracks: [Track] { entries.map(Track.init(entry:)) }
}
