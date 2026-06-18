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
final class SMBFileSource: FileSource {
    let id: String
    let displayName: String
    let kind: SourceKind = .smb
    let symbolName = "network"

    let config: SMBServerConfig

    #if canImport(SMBClient)
    private let connection: SMBConnection
    #endif

    init(config: SMBServerConfig, password: String) {
        self.id = config.sourceID
        self.displayName = config.displayName
        self.config = config
        #if canImport(SMBClient)
        self.connection = SMBConnection(config: config, password: password)
        #endif
    }

    func list(path: String) async throws -> [FileItem] {
        #if canImport(SMBClient)
        let files = try await connection.listDirectory(path: path)
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
        #else
        throw FileSourceError.smbUnavailable
        #endif
    }

    func fileURL(forPath path: String) async throws -> URL {
        #if canImport(SMBClient)
        let data = try await connection.download(path: path)
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
        _ = try await connection.listDirectory(path: "")
        #else
        throw FileSourceError.smbUnavailable
        #endif
    }
}

#if canImport(SMBClient)
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
    // `@unchecked Sendable` holders let us carry a non-Sendable result (SMBClient's
    // `File` isn't Sendable) and resume the continuation exactly once. The result
    // is written before its task finishes and read only after, so access is ordered.
    final class Box: @unchecked Sendable { var result: Result<T, Error>? }
    final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false
        func enter() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if finished { return false }
            finished = true
            return true
        }
    }
    let box = Box()
    let gate = Gate()
    let opTask = Task {
        do { box.result = .success(try await operation()) }
        catch { box.result = .failure(error) }
    }
    let timerTask = Task { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }

    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            Task {
                await opTask.value
                guard gate.enter() else { return }
                timerTask.cancel()
                continuation.resume(with: box.result ?? .failure(FileSourceError.timedOut))
            }
            Task {
                await timerTask.value
                guard gate.enter() else { return }
                opTask.cancel()
                continuation.resume(throwing: FileSourceError.timedOut)
            }
        }
    } onCancel: {
        opTask.cancel()
        timerTask.cancel()
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

    private func connectedClient() async throws -> SMBClient {
        if let client { return client }
        let host = config.host, port = config.port
        let username = config.isGuest ? "Guest" : config.username
        let secret = config.isGuest ? "" : password
        let share = config.share

        let client = SMBClient(host: host, port: port)
        try await withTimeout(connectTimeout) {
            try await client.login(username: username, password: secret)
            try await client.connectShare(share)
        }
        self.client = client
        return client
    }

    func listDirectory(path: String) async throws -> [File] {
        let client = try await connectedClient()
        return try await withTimeout(listTimeout) {
            try await client.listDirectory(path: path)
        }
    }

    func download(path: String) async throws -> Data {
        let client = try await connectedClient()
        return try await withTimeout(downloadTimeout) {
            try await client.download(path: path)
        }
    }
}
#endif
