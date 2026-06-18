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
final class LocalFileSource: FileSource {
    let id: String
    let displayName: String
    let kind: SourceKind
    let symbolName: String

    private let rootURL: URL
    private let isSecurityScoped: Bool
    private var didStartAccessing = false

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
        if isSecurityScoped {
            didStartAccessing = rootURL.startAccessingSecurityScopedResource()
        }
    }

    deinit {
        if isSecurityScoped && didStartAccessing {
            rootURL.stopAccessingSecurityScopedResource()
        }
    }

    private func url(forPath path: String) -> URL {
        path.isEmpty ? rootURL : rootURL.appendingPathComponent(path)
    }

    func list(path: String) async throws -> [FileItem] {
        let dir = url(forPath: path)
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
            // Skip non-audio, non-directory files to keep the browser tidy.
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
        let url = url(forPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw FileSourceError.fileNotFound(path)
        }
        return url
    }

    func directURL(forPath path: String) -> URL? {
        let url = url(forPath: path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
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
