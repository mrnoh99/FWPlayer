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
/// Owns a single `SMBClient`, connecting lazily on first use and serializing
/// every call so the underlying session is never used concurrently.
private actor SMBConnection {
    private let config: SMBServerConfig
    private let password: String
    private var client: SMBClient?

    init(config: SMBServerConfig, password: String) {
        self.config = config
        self.password = password
    }

    private func connectedClient() async throws -> SMBClient {
        if let client { return client }
        let client = SMBClient(host: config.host, port: config.port)
        if config.isGuest {
            try await client.login(username: "Guest", password: "")
        } else {
            try await client.login(username: config.username, password: password)
        }
        try await client.connectShare(config.share)
        self.client = client
        return client
    }

    func listDirectory(path: String) async throws -> [File] {
        let client = try await connectedClient()
        return try await client.listDirectory(path: path)
    }

    func download(path: String) async throws -> Data {
        let client = try await connectedClient()
        return try await client.download(path: path)
    }
}
#endif
