import Foundation
import Network

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
        if SACDVirtualPath.isImage(path) {                         // an SACD image: list its tracks
            let items = try await imageTracks(path: path)
            await listingCache.store(path: path, items: items)
            return items
        }
        do {
            let items = try await listFolder(path: path)
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
        if SACDVirtualPath.isImage(path) {
            let items = try await imageTracks(path: path)
            await listingCache.store(path: path, items: items)
            return items
        }
        let items = try await listFolder(path: path)
        await listingCache.store(path: path, items: items)
        return items
        #else
        throw FileSourceError.smbUnavailable
        #endif
    }

    #if canImport(SMBClient)
    /// Lists a folder. An error that isn't "not found" may mean the cached connection went
    /// bad (a long-idle or half-dead session), so reconnect and try once more; a second
    /// failure is reported with its real description instead of a generic "Unknown error".
    private func listFolder(path: String) async throws -> [FileItem] {
        do {
            return Self.items(from: try await listConnection.listDirectory(path: path), parent: path)
        } catch {
            if smbErrorIsObjectNotFound(error) { throw error }
            await listConnection.invalidate()
            do {
                return Self.items(from: try await listConnection.listDirectory(path: path), parent: path)
            } catch {
                if smbErrorIsObjectNotFound(error) { throw error }
                throw FileSourceError.smbFailure(smbDescribe(error))
            }
        }
    }
    #endif

    /// Walks the whole tree once, caching every listing to disk, then persists.
    /// Reports the number of folders scanned. Used after the server is added/edited.
    func prewarm(progress: @MainActor @escaping (Int) -> Void) async {
        #if canImport(SMBClient)
        await listingCache.clear()
        var scanned = 0
        var stack = [""]
        while let path = stack.popLast() {
            do {
                let items: [FileItem]
                if SACDVirtualPath.isImage(path) {
                    items = try await imageTracks(path: path)
                } else {
                    let files = try await listConnection.listDirectory(path: path)
                    items = Self.items(from: files, parent: path)
                }
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
        if let virtual = SACDVirtualPath.split(path) {
            return try await extractTrack(image: virtual.image, track: virtual.track)
        }
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

    /// Serves the file's bytes through ranged reads (no download first).
    func openByteStream(forPath path: String) async throws -> ByteSource {
        #if canImport(SMBClient)
        let size = try await downloadConnection.fileSize(path: path)
        return SMBRangeSource(path: path, size: size, connection: downloadConnection)
        #else
        throw FileSourceError.smbUnavailable
        #endif
    }

    func releaseTemporaryURL(_ url: URL) {
        // Only remove files inside our temp download directory.
        if url.path.contains("fwplayer-smb") {
            // (A track URL carries a "#track=N" fragment; remove by path.)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path))
        }
    }

    #if canImport(SMBClient)
    // MARK: SACD images (ranged reads: no need to download the whole image)

    private func readSectors(_ connection: SMBConnection, path: String, lsn: Int, count: Int) async throws -> [UInt8] {
        [UInt8](try await connection.readRange(path: path,
                                               offset: UInt64(lsn) * UInt64(SACDISO.sectorSize),
                                               length: UInt32(count * SACDISO.sectorSize)))
    }

    /// The tracks of an image, from a few ranged reads of its table of contents.
    private func imageTracks(path: String) async throws -> [FileItem] {
        let toc = try await SACDTOCPrefetch.load { lsn, count in
            try await self.readSectors(self.listConnection, path: path, lsn: lsn, count: count)
        }
        return SACDLibrary.trackItems(disc: try SACDISO.open(toc), imagePath: path)
    }

    /// Writes the TOC and one track's sectors into a sparse local copy of the image
    /// (at their original positions) and returns a URL addressing that track.
    private func extractTrack(image: String, track number: Int) async throws -> URL {
        let toc = try await SACDTOCPrefetch.load { lsn, count in
            try await self.readSectors(self.downloadConnection, path: image, lsn: lsn, count: count)
        }
        let disc = try SACDISO.open(toc)
        guard let area = disc.stereo else {
            throw SACDError.unsupported("This SACD has no stereo area (multichannel isn't supported).")
        }
        guard let track = area.tracks.first(where: { $0.number == number }) else {
            throw SACDError.noSuchTrack(number)
        }

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fwplayer-smb", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("\(UUID().uuidString).iso")
        guard FileManager.default.createFile(atPath: dest.path, contents: nil) else { throw SACDError.readFailed }
        let handle = try FileHandle(forWritingTo: dest)
        do {
            for segment in toc.segments {
                try handle.seek(toOffset: UInt64(segment.lsn) * UInt64(SACDISO.sectorSize))
                try handle.write(contentsOf: Data(segment.bytes))
            }
            var lsn = track.startLSN
            let end = track.startLSN + track.lengthLSN
            while lsn < end {
                try Task.checkCancellation()
                let count = min(2048, end - lsn)                    // 4 MB per read
                let bytes = try await readSectors(downloadConnection, path: image, lsn: lsn, count: count)
                guard !bytes.isEmpty else { break }
                try handle.seek(toOffset: UInt64(lsn) * UInt64(SACDISO.sectorSize))
                try handle.write(contentsOf: Data(bytes))
                lsn += bytes.count / SACDISO.sectorSize
                if bytes.count < count * SACDISO.sectorSize { break }
            }
            try handle.close()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: dest)
            throw error
        }
        return SACDISOTrackURL.make(dest, track: number)
    }
    #endif

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

    /// The size of a remote file.
    func fileSize(path: String) async throws -> UInt64 {
        do {
            return try await performFileSize(path: path)
        } catch {
            client = nil
            if smbShouldReconnect(error) {
                return try await performFileSize(path: path)
            }
            throw error
        }
    }

    private func performFileSize(path: String) async throws -> UInt64 {
        let client = try await connectedClient()
        return try await withTimeout(listTimeout) {
            try await client.fileStat(path: path).size
        }
    }

    /// Reads `length` bytes at `offset` of a remote file.
    func readRange(path: String, offset: UInt64, length: UInt32) async throws -> Data {
        do {
            return try await performReadRange(path: path, offset: offset, length: length)
        } catch {
            client = nil
            if smbShouldReconnect(error) {
                return try await performReadRange(path: path, offset: offset, length: length)
            }
            throw error
        }
    }

    private func performReadRange(path: String, offset: UInt64, length: UInt32) async throws -> Data {
        let client = try await connectedClient()
        return try await withTimeout(downloadTimeout) {
            let reader = client.fileReader(path: path)
            do {
                let data = try await reader.read(offset: offset, length: length)
                try? await reader.close()
                return data
            } catch {
                try? await reader.close()
                throw error
            }
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

/// A readable description of an SMB error (the generic localized text is often just
/// "Unknown error").
private func smbDescribe(_ error: Error) -> String {
    if let text = (error as? LocalizedError)?.errorDescription, !text.isEmpty { return text }
    if let response = error as? ErrorResponse { return "SMB status \(NTStatus(response.header.status))" }
    let ns = error as NSError
    return "\(type(of: error)) (\(ns.domain) \(ns.code)): \(error)"
}

private func smbShouldReconnect(_ error: Error) -> Bool {
    if error is FileSourceError { return true }
    // A socket-level failure (e.g. NWError 54 "Connection reset by peer" when the
    // server has dropped an idle SMB session) means the cached connection is dead
    // — a fresh login recovers, so treat it as reconnectable.
    if smbIsConnectionError(error) { return true }
    guard let err = error as? ErrorResponse else { return false }
    switch NTStatus(err.header.status) {
    case .objectNameNotFound, .userSessionDeleted, .networkNameDeleted, .connectionRefused,
         .networkSessionExpired, .fileClosed:
        return true
    default:
        return false
    }
}

/// Whether `error` is a network-transport failure (the socket died), as opposed
/// to an SMB-protocol status. Such errors mean the connection must be rebuilt.
private func smbIsConnectionError(_ error: Error) -> Bool {
    if error is NWError { return true }
    let ns = error as NSError
    if ns.domain == NSPOSIXErrorDomain {
        switch Int32(ns.code) {
        case ECONNRESET, EPIPE, ENOTCONN, ETIMEDOUT, ECONNABORTED,
             ENETDOWN, ENETRESET, ECONNREFUSED, EHOSTUNREACH, EHOSTDOWN, ENETUNREACH:
            return true
        default:
            return false
        }
    }
    // Fallback for errors that only stringify their cause (keeps us resilient to
    // however the SMB library surfaces a dropped socket).
    let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    let lowered = text.lowercased()
    return lowered.contains("reset by peer")
        || lowered.contains("not connected")
        || lowered.contains("broken pipe")
        || lowered.contains("connection abort")
        || lowered.contains("network is down")
        || lowered.contains("software caused connection")
}
#endif

extension SMBFileSource: ByteStreamingSource {}

#if canImport(SMBClient)
private final class ResultBox<T>: @unchecked Sendable {
    var value: Result<T, Error>?
}

/// A remote file read in 4 MB ranged chunks as the player asks for bytes. The player's
/// producer thread blocks here while a chunk arrives; the rest of playback is buffered.
private final class SMBRangeSource: ByteSource, @unchecked Sendable {
    let size: UInt64
    private let path: String
    private let connection: SMBConnection
    private let lock = NSLock()
    private var chunkOffset: UInt64 = 0
    private var chunk = Data()
    private static let chunkSize = 4 * 1024 * 1024

    init(path: String, size: UInt64, connection: SMBConnection) {
        self.path = path
        self.size = size
        self.connection = connection
    }

    func read(at offset: UInt64, length: Int) throws -> Data {
        guard length > 0, offset < size else { return Data() }
        lock.lock(); defer { lock.unlock() }
        var result = Data()
        var position = offset
        let end = min(size, offset + UInt64(length))
        while position < end {
            if position < chunkOffset || position >= chunkOffset + UInt64(chunk.count) {
                let want = Int(min(UInt64(Self.chunkSize), size - position))
                chunk = try fetch(offset: position, length: want)
                chunkOffset = position
                if chunk.isEmpty { break }
            }
            let start = chunk.startIndex + Int(position - chunkOffset)
            let take = Int(min(UInt64(chunk.count) - (position - chunkOffset), end - position))
            result.append(chunk[start..<(start + take)])
            position += UInt64(take)
        }
        return result
    }

    /// Blocks the calling (non-async) thread until the ranged read completes.
    private func fetch(offset: UInt64, length: Int) throws -> Data {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<Data>()
        let connection = self.connection, path = self.path
        Task.detached {
            do {
                box.value = .success(try await connection.readRange(path: path, offset: offset, length: UInt32(length)))
            } catch {
                box.value = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()
        return try (box.value ?? .failure(FileSourceError.timedOut)).get()
    }
}
#endif
