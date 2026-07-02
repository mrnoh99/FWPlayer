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
    private let ripQueue = CDRipQueue()
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
        return try await Task.detached(priority: .userInitiated) {
            let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .nameKey]
            let contents = try FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: keys,
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
            // Order by the leading track number when present ("1 Audio Track"),
            // falling back to a natural name compare.
            return items.sorted { CDAudioSource.trackOrder($0.name) < CDAudioSource.trackOrder($1.name) }
        }.value
    }

    /// Rips the track to a temp AIFF and returns that URL for playback.
    func fileURL(forPath path: String) async throws -> URL {
        let src = volumeURL.appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: src.path) else {
            throw FileSourceError.fileNotFound(path)
        }
        let dst = tempDir.appendingPathComponent(UUID().uuidString + ".aiff")
        try await ripQueue.rip(from: src, to: dst)
        return dst
    }

    /// Force the copy-to-temp path: reading CDDA files directly (per visible row,
    /// for artwork/metadata) would make the optical drive thrash, so no direct URL.
    func directURL(forPath path: String) -> URL? { nil }

    func releaseTemporaryURL(_ url: URL) {
        guard url.path.hasPrefix(tempDir.path) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Extracts a leading integer ("12 Audio Track.aiff" → 12) for track ordering.
    private static func trackOrder(_ name: String) -> Int {
        let digits = name.prefix { $0.isNumber }
        return Int(digits) ?? Int.max
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

/// Serializes CD-track copies so concurrent prefetch doesn't thrash the drive.
private actor CDRipQueue {
    func rip(from src: URL, to dst: URL) throws {
        if FileManager.default.fileExists(atPath: dst.path) {
            try FileManager.default.removeItem(at: dst)
        }
        try FileManager.default.copyItem(at: src, to: dst)
    }
}

#endif
