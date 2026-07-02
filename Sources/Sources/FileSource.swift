import Foundation

enum SourceKind {
    case localDocuments
    case localFolder
    case smb
    /// An inserted audio CD (Mac Catalyst only), mounted by macOS as a volume of
    /// AIFF tracks.
    case audioCD
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

    /// Re-lists `path`, bypassing any cached results (used for pull-to-refresh).
    func refresh(path: String) async throws -> [FileItem]

    /// Collects playable audio under `path`, optionally including subfolders.
    func audioItems(in path: String, recursive: Bool) async throws -> [FileItem]

    /// Whether any subdirectory holds playable audio (used for folder Play UI).
    func subfolderHasPlayableAudio(in path: String) async -> Bool
}

/// Sources that pre-scan folder listings into an on-disk cache for fast browsing.
protocol PrewarmableFileSource: FileSource {
    func needsPrewarm() async -> Bool
    func prewarm(progress: @MainActor @escaping (Int) -> Void) async
}

extension FileSource {
    func releaseTemporaryURL(_ url: URL) {}
    func directURL(forPath path: String) -> URL? { nil }
    /// By default there is no cache, so a refresh is just a list.
    func refresh(path: String) async throws -> [FileItem] { try await list(path: path) }

    /// Collects playable audio under `path`, optionally including subfolders.
    func audioItems(in path: String, recursive: Bool = true) async throws -> [FileItem] {
        try await collectAudioItems(in: path, recursive: recursive)
    }

    /// Shared recursive audio collection used by concrete sources.
    func collectAudioItems(in path: String, recursive: Bool) async throws -> [FileItem] {
        let entries = try await list(path: path)
        var audio = entries.filter { $0.kind == .audio }
        if recursive {
            for directory in entries where directory.kind == .directory {
                do {
                    audio.append(contentsOf: try await audioItems(in: directory.path, recursive: true))
                } catch {
                    continue
                }
            }
        }
        return audio.sorted {
            $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending
        }
    }

    func subfolderHasPlayableAudio(in path: String) async -> Bool {
        guard let entries = try? await list(path: path) else { return false }
        for item in entries where item.kind == .directory {
            let audio = (try? await audioItems(in: item.path, recursive: true)) ?? []
            if !audio.isEmpty { return true }
        }
        return false
    }
}

enum FileSourceError: LocalizedError {
    case notConnected
    case smbUnavailable
    case fileNotFound(String)
    case accessDenied
    case timedOut

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to the server."
        case .smbUnavailable: return "SMB support is not available in this build."
        case .fileNotFound(let path): return "File not found: \(path)"
        case .accessDenied: return "Access to this location was denied."
        case .timedOut: return "The server didn't respond in time. Check the host/IP, share, and that the server is reachable on this network."
        }
    }
}
