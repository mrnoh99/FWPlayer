import Foundation

/// Persisted connection details for an SMB server. The password is *not*
/// stored here — it lives in the Keychain, keyed by `id`.
struct SMBServerConfig: Identifiable, Codable, Hashable {
    let id: UUID
    var displayName: String
    var host: String
    var port: Int
    var share: String
    var username: String
    /// Whether to connect as a guest (no credentials).
    var isGuest: Bool

    init(id: UUID = UUID(),
         displayName: String,
         host: String,
         port: Int = 445,
         share: String,
         username: String = "",
         isGuest: Bool = false) {
        self.id = id
        self.displayName = displayName
        self.host = host
        self.port = port
        self.share = share
        self.username = username
        self.isGuest = isGuest
    }

    /// Stable identifier used as the `FileSource.id` for this server.
    var sourceID: String { "smb:" + id.uuidString }
}
