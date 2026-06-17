import Foundation

/// A playable audio track. Identified by the source it came from plus its
/// source-relative path, so the player can resolve it back to a local URL
/// (downloading from SMB if necessary) at playback time.
struct Track: Identifiable, Hashable {
    let sourceID: String
    let path: String
    let title: String
    var artist: String?
    var album: String?
    var duration: TimeInterval?

    var id: String { sourceID + "::" + path }

    init(sourceID: String, item: FileItem) {
        self.sourceID = sourceID
        self.path = item.path
        // Use the file name without extension as a reasonable default title.
        self.title = (item.name as NSString).deletingPathExtension
    }

    init(sourceID: String, path: String, title: String) {
        self.sourceID = sourceID
        self.path = path
        self.title = title
    }

    init(entry: PlaylistEntry) {
        self.init(sourceID: entry.sourceID, path: entry.path, title: entry.title)
    }
}
