import Foundation
import SwiftUI

/// Holds every active `FileSource` (the built-in Documents folder, user-added
/// local folders, and SMB servers) and owns their persistence.
@MainActor
final class SourceRegistry: ObservableObject {
    @Published private(set) var sources: [any FileSource] = []

    private let bookmarkStore = BookmarkStore()
    private let smbStore = SMBServerStore()

    private let documentsSourceID = "local:documents"

    /// Builds the source list from persisted bookmarks and SMB configs.
    func loadPersisted() {
        var loaded: [any FileSource] = []

        // Always expose the app's own Documents directory.
        if let documents = try? FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true) {
            loaded.append(LocalFileSource(
                id: documentsSourceID,
                displayName: "On This Device",
                rootURL: documents,
                kind: .localDocuments,
                isSecurityScoped: false
            ))
        }

        // User-selected folders (security-scoped bookmarks).
        for entry in bookmarkStore.load() {
            guard let resolved = try? BookmarkStore.resolve(entry.bookmark) else { continue }
            loaded.append(LocalFileSource(
                id: entry.id,
                displayName: entry.displayName,
                rootURL: resolved.url,
                kind: .localFolder,
                isSecurityScoped: true
            ))
        }

        // SMB servers.
        for config in smbStore.load() {
            let password = smbStore.password(for: config)
            loaded.append(SMBFileSource(config: config, password: password))
        }

        sources = loaded
    }

    func source(for id: String) -> (any FileSource)? {
        sources.first { $0.id == id }
    }

    // MARK: - Local folders

    func addLocalFolder(url: URL) throws {
        let bookmark = try BookmarkStore.makeBookmark(for: url)
        let id = "local:" + UUID().uuidString
        let name = url.lastPathComponent
        bookmarkStore.add(.init(id: id, displayName: name, bookmark: bookmark))
        sources.append(LocalFileSource(
            id: id,
            displayName: name,
            rootURL: url,
            kind: .localFolder,
            isSecurityScoped: true
        ))
    }

    // MARK: - SMB servers

    func addSMBServer(_ config: SMBServerConfig, password: String) {
        smbStore.add(config, password: password)
        sources.append(SMBFileSource(config: config, password: password))
    }

    /// Updates an existing SMB server's settings and rebuilds its live source so
    /// the new host/share/credentials take effect (the old connection is dropped).
    func updateSMBServer(_ config: SMBServerConfig, password: String) {
        smbStore.add(config, password: password)   // upsert by id
        let updated = SMBFileSource(config: config, password: password)
        if let index = sources.firstIndex(where: { $0.id == config.sourceID }) {
            sources[index] = updated
        } else {
            sources.append(updated)
        }
    }

    /// The stored password for an SMB server, for pre-filling the edit form.
    func smbPassword(for config: SMBServerConfig) -> String {
        smbStore.password(for: config)
    }

    // MARK: - Removal

    func remove(_ source: any FileSource) {
        guard source.id != documentsSourceID else { return }
        if let smb = source as? SMBFileSource {
            smbStore.remove(id: smb.config.id)
        } else {
            bookmarkStore.remove(id: source.id)
        }
        sources.removeAll { $0.id == source.id }
    }
}
