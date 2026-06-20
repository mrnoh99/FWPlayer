import Foundation

#if canImport(SMBClient)
import SMBClient
#endif

/// A `FileSource` backed by a remote SMB (CIFS) share, reached directly over
/// the local network. Files are downloaded to a temporary location for
/// playback. All access to the underlying connection is serialized by an actor.
///
/// The actual SMB protocol work is provided by the `SMBClient` Swift package.
/// When that package is not present the source still compiles, but every
/// operation reports `FileSourceError.smbUnavailable`.
final class SMBFileSource: FileSource, PrewarmableFileSource {
    let id: String
    let displayName: String
    let kind: SourceKind = .smb
    let symbolName = "network"

    let config: SMBServerConfig

    /// Persistent on-disk cache of this server's folder listings.
    private let listingCache: FolderListingCache

    #if canImport(SMBClient)
    /// Directory listings (interactive browsing) and file downloads (playback)
    /// each get their own SMB session. A single shared session serializes
    /// everything, so prefetching upcoming tracks would block folder browsing
    /// during playback. Two sessions let a browse complete without waiting behind
    /// downloads.
    private let listConnection: SMBConnection
    private let downloadConnection: SMBConnection
    #endif

    init(config: SMBServerConfig, password: String) {
        self.id = config.sourceID
        self.displayName = config.displayName
        self.config = config
        self.listingCache = FolderListingCache(subdirectory: "SMBCache", sourceID: config.id.uuidString)
        #if canImport(SMBClient)
        self.listConnection = SMBConnection(config: config, password: password)
        self.downloadConnection = SMBConnection(config: config, password: password)
        Task { [listingCache] in
            let cacheEmpty = await listingCache.isEmpty
            if !cacheEmpty {
                await listingCache.computePlayabilityIndex()
            }
        }
        #endif
    }

    func needsPrewarm() async -> Bool {
        await listingCache.isEmpty
    }

    func list(path: String) async throws -> [FileItem] {
        #if canImport(SMBClient)
        // The on-disk cache makes browsing instant after the one-time pre-scan
        // (and across app restarts).
        if let cached = await listingCache.listing(path: path) { return cached }
        do {
            let files = try await listConnection.listDirectory(path: path)
            let items = Self.items(from: files, parent: path)
            await listingCache.store(path: path, items: items)
            return items
        } catch {
            if smbErrorIsObjectNotFound(error) {
                await listingCache.store(path: path, items: [])
                return []
            }
            throw error
        }
        #else
        throw FileSourceError.smbUnavailable
        #endif
    }

    func refresh(path: String) async throws -> [FileItem] {
        #if canImport(SMBClient)
        let files = try await listConnection.listDirectory(path: path)
        let items = Self.items(from: files, parent: path)
        await listingCache.store(path: path, items: items)
        return items
        #else
        throw FileSourceError.smbUnavailable
        #endif
    }

    /// Walks the whole tree once, caching every listing to disk, then persists.
    /// Reports the number of folders scanned. Used after the server is added/edited.
    func prewarm(progress: @MainActor @escaping (Int) -> Void) async {
        #if canImport(SMBClient)
        await listingCache.clear()
        var scanned = 0
        var stack = [""]
        while let path = stack.popLast() {
            do {
                let files = try await listConnection.listDirectory(path: path)
                let items = Self.items(from: files, parent: path)
                await listingCache.store(path: path, items: items, persist: false)
                scanned += 1
                await progress(scanned)
                for item in items where item.kind == .directory {
                    stack.append(item.path)
                }
            } catch {
                // Cache an empty listing so later browsing doesn't retry paths that
                // don't exist on the server (symlinks, stale entries, etc.).
                await listingCache.store(path: path, items: [], persist: false)
                scanned += 1
                await progress(scanned)
            }
        }
        await listingCache.flush()
        await listingCache.computePlayabilityIndex()
        await listConnection.invalidate()
        #endif
    }

    /// Cache-only: does `path` or any descendant contain playable audio?
    func hasPlayableAudio(in path: String) async -> Bool {
        let cacheEmpty = await listingCache.isEmpty
        if !cacheEmpty { return await listingCache.hasPlayableAudio(in: path) }
        return ((try? await collectAudioItems(in: path, recursive: true))?.isEmpty == false)
    }

    /// Cache-only: does any subdirectory under `path` contain playable audio?
    func subfolderHasPlayableAudio(in path: String) async -> Bool {
        let cacheEmpty = await listingCache.isEmpty
        if !cacheEmpty { return await listingCache.subfolderHasPlayableAudio(in: path) }
        guard let entries = try? await list(path: path) else { return false }
        for item in entries where item.kind == .directory {
            if await hasPlayableAudio(in: item.path) { return true }
        }
        return false
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

    #if canImport(SMBClient)
    /// Maps raw SMB entries to browsable `FileItem`s (folders + playable audio).
    private static func items(from files: [File], parent path: String) -> [FileItem] {
        var items: [FileItem] = []
        for file in files {
            let name = file.name
            if name == "." || name == ".." { continue }
            let kind = FileItem.kind(forName: name, isDirectory: file.isDirectory)
            guard kind != .other else { continue }
            let relativePath = path.isEmpty ? name : path + "/" + name
            items.append(FileItem(
                path: relativePath,
                name: name,
                kind: kind,
                size: Int64(exactly: file.size),
                modified: nil
            ))
        }
        return items.sortedForBrowsing()
    }
    #endif

    func fileURL(forPath path: String) async throws -> URL {
        #if canImport(SMBClient)
        let data = try await downloadConnection.download(path: path)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fwplayer-smb", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent((path as NSString).lastPathComponent)
        try data.write(to: dest, options: .atomic)
        return dest
        #else
        throw FileSourceError.smbUnavailable
        #endif
    }

    func releaseTemporaryURL(_ url: URL) {
        // Only remove files inside our temp download directory.
        if url.path.contains("fwplayer-smb") {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Verifies that the configured credentials and share are reachable.
    func testConnection() async throws {
        #if canImport(SMBClient)
        _ = try await listConnection.listDirectory(path: "")
        #else
        throw FileSourceError.smbUnavailable
        #endif
    }

    /// Maps SMB protocol errors to clearer guidance in the add-server form.
    static func userFacingMessage(for error: Error) -> String {
        #if canImport(SMBClient)
        return smbClientUserFacingMessage(for: error)
        #else
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        #endif
    }
}

#if canImport(SMBClient)
private func smbErrorIsObjectNotFound(_ error: Error) -> Bool {
    guard let err = error as? ErrorResponse else { return false }
    return NTStatus(err.header.status) == .objectNameNotFound
}

/// Maps SMBClient `ErrorResponse` statuses to user-facing text.
private func smbClientUserFacingMessage(for error: Error) -> String {
    if let err = error as? ErrorResponse {
        switch NTStatus(err.header.status) {
        case .logonFailure:
            return "Login failed. Check username and password, enable guest access on the server if using Guest, or try DOMAIN\\username for Windows/Synology accounts."
        case .badNetworkName:
            return "Share not found. Use the share name only (e.g. Music), not a path."
        case .accessDenied:
            return "Access denied. The account may not have permission for this share."
        case .objectNameNotFound:
            return "Folder not found on the server. It may have been moved or removed."
        default:
            break
        }
    }
    return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
}

/// Splits `DOMAIN\username` entered in the username field for NTLM login.
private func parseSMBLogin(username: String, password: String, isGuest: Bool)
    -> (username: String?, password: String?, domain: String?) {
    if isGuest { return (nil, nil, nil) }
    if let slash = username.firstIndex(of: "\\") {
        let domain = String(username[..<slash])
        let account = String(username[username.index(after: slash)...])
        return (account, password, domain.isEmpty ? nil : domain)
    }
    return (username, password, nil)
}

/// Runs `operation`, throwing `FileSourceError.timedOut` if it doesn't finish
/// within `seconds`. Prevents a stalled SMB call from hanging the UI forever
/// (the browser would otherwise spin on "Loading…" with no error). Real errors
/// thrown by `operation` propagate unchanged.
///
/// The operation runs in an *unstructured* task that is abandoned on timeout, so
/// the caller is freed even if the underlying SMB call doesn't observe
/// cancellation — exactly the case that caused the endless spinner.
func withTimeout<T>(_ seconds: TimeInterval,
                    _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw FileSourceError.timedOut
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else {
            throw FileSourceError.timedOut
        }
        return result
    }
}

/// Owns a single `SMBClient`, connecting lazily on first use and serializing
/// every call so the underlying session is never used concurrently.
private actor SMBConnection {
    /// Timeouts (seconds). Connecting and listing must respond promptly; a file
    /// download may legitimately take longer.
    private let connectTimeout: TimeInterval = 20
    private let listTimeout: TimeInterval = 30
    private let downloadTimeout: TimeInterval = 300

    private let config: SMBServerConfig
    private let password: String
    private var client: SMBClient?

    init(config: SMBServerConfig, password: String) {
        self.config = config
        self.password = password
    }

    func invalidate() {
        client = nil
    }

    private func connectedClient() async throws -> SMBClient {
        if let client { return client }
        let host = config.host, port = config.port
        let share = config.share
        let login = parseSMBLogin(
            username: config.username,
            password: password,
            isGuest: config.isGuest
        )

        let client = SMBClient(host: host, port: port)
        try await withTimeout(connectTimeout) {
            try await client.login(
                username: login.username,
                password: login.password,
                domain: login.domain
            )
            try await client.connectShare(share)
        }
        self.client = client
        return client
    }

    func listDirectory(path: String) async throws -> [File] {
        do {
            return try await performListDirectory(path: path)
        } catch {
            client = nil
            if smbShouldReconnect(error) {
                return try await performListDirectory(path: path)
            }
            throw error
        }
    }

    func download(path: String) async throws -> Data {
        do {
            return try await performDownload(path: path)
        } catch {
            client = nil
            if smbShouldReconnect(error) {
                return try await performDownload(path: path)
            }
            throw error
        }
    }

    private func performListDirectory(path: String) async throws -> [File] {
        let client = try await connectedClient()
        return try await withTimeout(listTimeout) {
            try await client.listDirectory(path: path)
        }
    }

    private func performDownload(path: String) async throws -> Data {
        let client = try await connectedClient()
        return try await withTimeout(downloadTimeout) {
            try await client.download(path: path)
        }
    }
}

private func smbShouldReconnect(_ error: Error) -> Bool {
    if error is FileSourceError { return true }
    guard let err = error as? ErrorResponse else { return false }
    switch NTStatus(err.header.status) {
    case .objectNameNotFound, .userSessionDeleted, .networkNameDeleted, .connectionRefused,
         .networkSessionExpired, .fileClosed:
        return true
    default:
        return false
    }
}
#endif
