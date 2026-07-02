import Foundation

#if targetEnvironment(macCatalyst)

/// A `FileSource` backed by an inserted audio CD on a Mac.
///
/// macOS mounts an audio CD as a volume (under `/Volumes`) using the `cddafs`
/// file system, presenting each CDDA track as an AIFF file (e.g.
/// "1 Audio Track.aiff"). We list those tracks and, on play, copy ("rip") the
/// chosen track to a temp file so `AVAudioPlayer` reads from fast local storage
/// instead of streaming from the optical drive — the same download-to-temp
/// pattern the SMB source uses.
///
/// CD reads are serialized through an actor so prefetching upcoming tracks
/// doesn't make one optical drive seek-thrash between several tracks at once.
final class CDAudioSource: FileSource {
    let id: String
    let displayName: String
    let kind: SourceKind = .audioCD
    let symbolName = "opticaldisc"

    /// The mounted CD volume, e.g. `/Volumes/Audio CD`.
    let volumeURL: URL
    /// Serializes *every* access to the optical drive — directory listing and
    /// track ripping alike. Overlapping reads make the drive seek-thrash, which
    /// produces read errors that macOS resolves by ejecting the disc.
    private let discQueue = CDDiscQueue()
    private let tempDir: URL

    init(volumeURL: URL) {
        self.volumeURL = volumeURL
        // Identity is tied to the mount path so the same disc keeps its id while
        // inserted, and a re-inserted disc rebuilds cleanly.
        self.id = "cd:" + volumeURL.path
        self.displayName = volumeURL.lastPathComponent
        self.tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CDRip", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    func list(path: String) async throws -> [FileItem] {
        // An audio CD is flat: all tracks live at the volume root.
        let dir = path.isEmpty ? volumeURL : volumeURL.appendingPathComponent(path)
        return try await discQueue.list(dir: dir, path: path)
    }

    /// Rips the track to a temp AIFF and returns that URL for playback.
    func fileURL(forPath path: String) async throws -> URL {
        let src = volumeURL.appendingPathComponent(path)
        let dst = tempDir.appendingPathComponent(UUID().uuidString + ".aiff")
        try await discQueue.rip(from: src, to: dst)
        return dst
    }

    /// Force the copy-to-temp path: reading CDDA files directly (per visible row,
    /// for artwork/metadata) would make the optical drive thrash, so no direct URL.
    func directURL(forPath path: String) -> URL? { nil }

    func releaseTemporaryURL(_ url: URL) {
        guard url.path.hasPrefix(tempDir.path) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Detection

    /// Scans mounted volumes and returns the ones that are audio CDs.
    static func mountedAudioCDVolumes() -> [URL] {
        let keys: [URLResourceKey] = [.volumeIsBrowsableKey]
        guard let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) else {
            return []
        }
        return volumes.filter { isAudioCDVolume($0) }
    }

    /// An audio CD volume is identified by its `cddafs` file-system type.
    private static func isAudioCDVolume(_ url: URL) -> Bool {
        var stat = statfs()
        guard statfs(url.path, &stat) == 0 else { return false }
        let fsType = withUnsafePointer(to: &stat.f_fstypename) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { String(cString: $0) }
        }
        return fsType == "cddafs"
    }
}

/// Serializes every optical-drive access (listing and ripping) so the drive is
/// only ever asked to do one thing at a time — overlapping reads cause the read
/// errors that make macOS eject the disc.
private actor CDDiscQueue {
    func list(dir: URL, path: String) throws -> [FileItem] {
        let contents = try FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        var items: [FileItem] = []
        for url in contents {
            let name = url.lastPathComponent
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            let kind = FileItem.kind(forName: name, isDirectory: isDir)
            guard kind == .audio else { continue }
            let relativePath = path.isEmpty ? name : path + "/" + name
            items.append(FileItem(path: relativePath, name: name, kind: kind, size: nil, modified: nil))
        }
        // Order by the leading track number ("1 Audio Track" → 1) when present.
        return items.sorted { Self.trackOrder($0.name) < Self.trackOrder($1.name) }
    }

    func rip(from src: URL, to dst: URL) throws {
        guard FileManager.default.fileExists(atPath: src.path) else {
            throw FileSourceError.fileNotFound(src.lastPathComponent)
        }
        if FileManager.default.fileExists(atPath: dst.path) {
            try FileManager.default.removeItem(at: dst)
        }
        try FileManager.default.copyItem(at: src, to: dst)
    }

    /// Extracts a leading integer ("12 Audio Track.aiff" → 12) for track ordering.
    private static func trackOrder(_ name: String) -> Int {
        let digits = name.prefix { $0.isNumber }
        return Int(digits) ?? Int.max
    }
}

#endif
