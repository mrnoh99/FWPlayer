import CoreTransferable
import Foundation
import UniformTypeIdentifiers

extension UTType {
    static let fwplayerTrack = UTType(exportedAs: "com.fwplayer.track")
}

/// A playable audio track. Identified by the source it came from plus its
/// source-relative path, so the player can resolve it back to a local URL
/// (downloading from SMB if necessary) at playback time.
struct Track: Identifiable, Hashable, Codable, Transferable {
    let sourceID: String
    let path: String
    let title: String
    var artist: String?
    var album: String?
    /// Release year, e.g. "1986", from the file's metadata or the Apple Music
    /// Catalog (MusicKit) lookup.
    var year: String?
    /// Primary genre, e.g. "Jazz", resolved from the Apple Music Catalog.
    var genre: String?
    var duration: TimeInterval?
    var sampleRate: Double?
    /// Classical: composer and work (e.g. "Symphony No. 5"), from the file's tags.
    var composer: String?
    var work: String?

    /// Composer, work and performers on one line (classical-friendly); nil when no tag
    /// is known. The work is left out when the title already says it.
    var artistLine: String? {
        var parts: [String] = []
        if let composer, !composer.isEmpty { parts.append(composer) }
        if let work, !work.isEmpty, !title.localizedCaseInsensitiveContains(work) { parts.append(work) }
        if let artist, !artist.isEmpty { parts.append(artist) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

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

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .fwplayerTrack)
    }
}
