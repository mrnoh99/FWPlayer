import Foundation

#if targetEnvironment(macCatalyst)

/// A `FileSource` backed by an inserted audio CD on a Mac.
///
/// macOS mounts an audio CD as a volume (under `/Volumes`) using the `cddafs`
/// file system, presenting each CDDA track as an AIFF file (e.g.
/// "1 Audio Track.aiff"). We list those tracks and, on play, hand the track's
/// on-disc URL straight to `AVAudioPlayer`, which streams it at 1× — the way
/// QuickTime plays a CD.
///
/// We intentionally do not rip the whole track to a temp file first: that reads
/// the disc at full speed with heavy seeking, which is slow to start and stresses
/// the drive into ejecting. The player also never prefetches CD tracks, so the
/// drive is only ever asked to read the one track that's currently playing.
final class CDAudioSource: FileSource {
    let id: String
    let displayName: String
    let kind: SourceKind = .audioCD
    let symbolName = "opticaldisc"

    /// The mounted CD volume, e.g. `/Volumes/Audio CD`.
    let volumeURL: URL
    /// Serializes optical-drive directory listings so two browse reads never
    /// seek against each other (playback streams straight from the disc).
    private let discQueue = CDDiscQueue()

    init(volumeURL: URL) {
        self.volumeURL = volumeURL
        // Identity is tied to the mount path so the same disc keeps its id while
        // inserted, and a re-inserted disc rebuilds cleanly.
        self.id = "cd:" + volumeURL.path
        self.displayName = volumeURL.lastPathComponent
    }

    func list(path: String) async throws -> [FileItem] {
        // An audio CD is flat: all tracks live at the volume root.
        let dir = path.isEmpty ? volumeURL : volumeURL.appendingPathComponent(path)
        return try await discQueue.list(dir: dir, path: path)
    }

    /// Returns the track's URL on the mounted disc so `AVAudioPlayer` streams it
    /// at playback rate (1×) — the same way QuickTime plays a CD.
    ///
    /// We deliberately do NOT copy ("rip") the whole track to a temp file first:
    /// a full-track copy slurps the disc at maximum speed with heavy seeking and
    /// error correction, which is slow (tens of seconds before the first note)
    /// and stresses the drive enough that macOS ejects the disc. Streaming reads
    /// sequentially at 1×, which is exactly what optical drives are built for.
    func fileURL(forPath path: String) async throws -> URL {
        let src = volumeURL.appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: src.path) else {
            throw FileSourceError.fileNotFound(path)
        }
        return src
    }

    /// No cheap synchronous URL: this is called per visible row for
    /// artwork/metadata, and letting that hit the disc would seek against
    /// playback. Playback resolves the URL through `fileURL(forPath:)` instead.
    func directURL(forPath path: String) -> URL? { nil }

    /// Nothing to release — playback streams straight from the disc, so no temp
    /// file was created.
    func releaseTemporaryURL(_ url: URL) {}

    // MARK: - Detection

    /// Scans mounted volumes and returns the ones that are audio CDs.
    ///
    /// Passes no resource keys so the enumeration reads only the in-memory mount
    /// table; identification is done with `statfs` (also mount-table metadata),
    /// so this never spins or probes the optical drive.
    static func mountedAudioCDVolumes() -> [URL] {
        guard let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) else {
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

/// Serializes optical-drive directory listings so two browse reads never seek
/// against each other. (Playback streams straight from the disc via
/// `AVAudioPlayer`, so it isn't routed through here.)
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

    /// Extracts a leading integer ("12 Audio Track.aiff" → 12) for track ordering.
    private static func trackOrder(_ name: String) -> Int {
        let digits = name.prefix { $0.isNumber }
        return Int(digits) ?? Int.max
    }
}

#endif
