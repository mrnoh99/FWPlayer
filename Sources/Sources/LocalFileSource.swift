import Foundation

/// A `FileSource` backed by a directory on the local file system.
///
/// Two flavours are supported:
///  * the app's own Documents directory (files added via Finder/iTunes file
///    sharing, AirDrop, or "Save to Files"), which needs no security scope, and
///  * a user-selected folder picked through the document picker, which is
///    reached via a persisted security-scoped bookmark. Folders the user has
///    connected in the Files app (including SMB shares mounted there) can be
///    selected this way too.
///
/// On Mac Catalyst, connected folders are pre-scanned into a listing cache so
/// browsing large libraries stays responsive.
final class LocalFileSource: FileSource, PrewarmableFileSource {
    let id: String
    let displayName: String
    let kind: SourceKind
    let symbolName: String

    private let rootURL: URL
    private let isSecurityScoped: Bool
    private var didStartAccessing = false
    private let listingCache: FolderListingCache

    init(id: String,
         displayName: String,
         rootURL: URL,
         kind: SourceKind,
         isSecurityScoped: Bool) {
        self.id = id
        self.displayName = displayName
        self.rootURL = rootURL
        self.kind = kind
        self.isSecurityScoped = isSecurityScoped
        self.symbolName = kind == .localDocuments ? "folder.fill" : "externaldrive.fill"
        self.listingCache = FolderListingCache(subdirectory: "LocalCache", sourceID: id)
        if isSecurityScoped {
            didStartAccessing = rootURL.startAccessingSecurityScopedResource()
        }
        Task { [listingCache] in
            let cacheEmpty = await listingCache.isEmpty
            if !cacheEmpty {
                await listingCache.computePlayabilityIndex()
            }
        }
    }

    deinit {
        if isSecurityScoped && didStartAccessing {
            rootURL.stopAccessingSecurityScopedResource()
        }
    }

    func needsPrewarm() async -> Bool {
        await listingCache.isEmpty
    }

    func prewarm(progress: @MainActor @escaping (Int) -> Void) async {
        await listingCache.clear()
        var scanned = 0
        var stack = [""]
        while let path = stack.popLast() {
            do {
                let items = try await listFromDisk(path: path)
                await listingCache.store(path: path, items: items, persist: false)
                scanned += 1
                await progress(scanned)
                for item in items where item.kind == .directory {
                    stack.append(item.path)
                }
            } catch {
                // Don't cache failed reads — list() will retry from disk later.
                scanned += 1
                await progress(scanned)
            }
        }
        await listingCache.flush()
        await listingCache.computePlayabilityIndex()
    }

    private func url(forPath path: String) -> URL {
        path.isEmpty ? rootURL : rootURL.appendingPathComponent(path)
    }

    func list(path: String) async throws -> [FileItem] {
        if let cached = await listingCache.listing(path: path) { return cached }
        let items = try await listFromDisk(path: path)
        await listingCache.store(path: path, items: items)
        return items
    }

    func refresh(path: String) async throws -> [FileItem] {
        let items = try await listFromDisk(path: path)
        await listingCache.store(path: path, items: items)
        return items
    }

    func audioItems(in path: String, recursive: Bool = true) async throws -> [FileItem] {
        let cacheEmpty = await listingCache.isEmpty
        if !cacheEmpty {
            if recursive {
                return await listingCache.recursiveAudio(in: path)
            }
            return (await listingCache.listing(path: path) ?? []).filter { $0.kind == .audio }
        }
        return try await collectAudioItems(in: path, recursive: recursive)
    }

    func subfolderHasPlayableAudio(in path: String) async -> Bool {
        let cacheEmpty = await listingCache.isEmpty
        if !cacheEmpty { return await listingCache.subfolderHasPlayableAudio(in: path) }
        // No cache (e.g. Catalyst local, which we don't pre-scan): walk the tree
        // live, but bail the moment the caller cancels (the user navigated away)
        // so this scan stops hogging the listing cache and slowing the next open.
        guard !Task.isCancelled, let entries = try? await list(path: path) else { return false }
        for item in entries where item.kind == .directory {
            if Task.isCancelled { return false }
            if await hasPlayableAudio(in: item.path) { return true }
        }
        return false
    }

    private func hasPlayableAudio(in path: String) async -> Bool {
        guard !Task.isCancelled, let entries = try? await list(path: path) else { return false }
        if entries.contains(where: { $0.kind == .audio }) { return true }
        for item in entries where item.kind == .directory {
            if Task.isCancelled { return false }
            if await hasPlayableAudio(in: item.path) { return true }
        }
        return false
    }

    private func ensureSecurityScopedAccess() throws {
        guard isSecurityScoped else { return }
        if !didStartAccessing {
            didStartAccessing = rootURL.startAccessingSecurityScopedResource()
        }
        guard didStartAccessing else {
            throw FileSourceError.accessDenied
        }
    }

    /// Reads a directory from disk **off the main thread**.
    ///
    /// `contentsOfDirectory` can be slow for network-mounted folders — e.g. an
    /// SMB share the user connected in the Files app and added here as a "local"
    /// folder — because each call is a round-trip to the server. On the Mac this
    /// is the common case, so running it on the main actor would freeze the UI
    /// and make opening a folder feel like a hang (the Finder stays quick because
    /// it enumerates directories on background threads). Hopping to a detached
    /// task keeps browsing responsive regardless of where the folder lives.
    private func listFromDisk(path: String) async throws -> [FileItem] {
        try ensureSecurityScopedAccess()
        let dir = url(forPath: path)
        return try await Task.detached(priority: .userInitiated) {
            try Self.readDirectory(at: dir, parentPath: path)
        }.value
    }

    private static func readDirectory(at dir: URL, parentPath path: String) throws -> [FileItem] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .nameKey]
        let contents = try FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )

        var items: [FileItem] = []
        for url in contents {
            let values = try? url.resourceValues(forKeys: Set(keys))
            let isDir = values?.isDirectory ?? false
            let name = url.lastPathComponent
            let kind = FileItem.kind(forName: name, isDirectory: isDir)
            guard kind != .other else { continue }
            let relativePath = path.isEmpty ? name : path + "/" + name
            items.append(FileItem(
                path: relativePath,
                name: name,
                kind: kind,
                size: values?.fileSize.map(Int64.init),
                modified: values?.contentModificationDate
            ))
        }
        return items.sortedForBrowsing()
    }

    func fileURL(forPath path: String) async throws -> URL {
        try ensureSecurityScopedAccess()
        let url = url(forPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw FileSourceError.fileNotFound(path)
        }
        return url
    }

    func directURL(forPath path: String) -> URL? {
        guard (try? ensureSecurityScopedAccess()) != nil else { return nil }
        // Return the URL without a `fileExists` check: this is called
        // synchronously for every visible row on the main thread, and for a
        // network-mounted folder that stat is a per-row round-trip to the server
        // that stalls scrolling. Callers that actually open the file handle a
        // missing path gracefully (artwork/metadata simply don't load).
        return url(forPath: path)
    }
}

extension Array where Element == FileItem {
    /// Directories first, then files, each alphabetically (case-insensitive).
    func sortedForBrowsing() -> [FileItem] {
        sorted { lhs, rhs in
            if (lhs.kind == .directory) != (rhs.kind == .directory) {
                return lhs.kind == .directory
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }
}
