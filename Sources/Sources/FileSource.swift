import Foundation

enum SourceKind {
    case localDocuments
    case localFolder
    case smb
}

/// Abstraction over a browsable, playable file location. Concrete
/// implementations exist for the on-device Documents folder, user-selected
/// local folders (via security-scoped bookmarks), and SMB network shares.
protocol FileSource: AnyObject, Identifiable {
    /// Stable identifier, also stored on `Track` so playback can resolve files.
    var id: String { get }
    var displayName: String { get }
    var kind: SourceKind { get }
    /// SF Symbol name used for this source in the sidebar.
    var symbolName: String { get }

    /// Lists the entries directly contained at `path` (source-relative, "" = root).
    func list(path: String) async throws -> [FileItem]

    /// Returns a local file URL that AVAudioPlayer can read. For remote sources
    /// this downloads the file to a temporary location.
    func fileURL(forPath path: String) async throws -> URL

    /// When the file is already on disk, returns its URL without downloading.
    func directURL(forPath path: String) -> URL?

    /// Releases any temporary resource created by `fileURL(forPath:)`.
    func releaseTemporaryURL(_ url: URL)
}

extension FileSource {
    func releaseTemporaryURL(_ url: URL) {}
    func directURL(forPath path: String) -> URL? { nil }

    /// Collects playable audio under `path`, optionally including subfolders.
    func audioItems(in path: String, recursive: Bool = true) async throws -> [FileItem] {
        let entries = try await list(path: path)
        var audio = entries.filter { $0.kind == .audio }
        if recursive {
            for directory in entries where directory.kind == .directory {
                audio.append(contentsOf: try await audioItems(in: directory.path, recursive: true))
            }
        }
        return audio.sorted {
            $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending
        }
    }
}

enum FileSourceError: LocalizedError {
    case notConnected
    case smbUnavailable
    case fileNotFound(String)
    case accessDenied

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to the server."
        case .smbUnavailable: return "SMB support is not available in this build."
        case .fileNotFound(let path): return "File not found: \(path)"
        case .accessDenied: return "Access to this location was denied."
        }
    }
}
