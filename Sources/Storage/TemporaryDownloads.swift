import Foundation

/// Files downloaded from a share for playback. Each lives in a folder of its own, so
/// two tracks with the same file name (two albums' "Track 01.m4a", both read ahead)
/// never overwrite or delete each other.
enum TemporaryDownloads {
    static var root: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("fwplayer-smb", isDirectory: true)
    }

    /// A new, unused place for a download called `name`.
    static func newFileURL(named name: String, in root: URL = root) throws -> URL {
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(name.isEmpty ? "download" : name)
    }

    /// Whether `url` is a download of ours (anything else is never removed).
    static func contains(_ url: URL, in root: URL = root) -> Bool {
        let path = URL(fileURLWithPath: url.path).standardizedFileURL.path
        return path.hasPrefix(root.standardizedFileURL.path + "/")
    }

    /// Removes a download, and the folder made for it. A track URL can carry a
    /// "#track=N" fragment; only the path counts.
    static func remove(_ url: URL, in root: URL = root) {
        guard contains(url, in: root) else { return }
        let file = URL(fileURLWithPath: url.path).standardizedFileURL
        try? FileManager.default.removeItem(at: file)
        let folder = file.deletingLastPathComponent()
        if folder.path != root.standardizedFileURL.path, contains(folder, in: root) {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    /// Removes every download, e.g. ones left behind when the app last quit mid-track.
    static func removeAll(in root: URL = root) {
        try? FileManager.default.removeItem(at: root)
    }
}
