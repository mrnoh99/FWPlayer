import Foundation
import SwiftUI

/// Background pre-scan progress for an SMB server.
struct SMBScanProgress: Equatable {
    var isScanning: Bool
    var foldersScanned: Int
}

/// Holds every active `FileSource` (the built-in Documents folder on iOS,
/// user-added local folders, and SMB servers) and owns their persistence.
@MainActor
final class SourceRegistry: ObservableObject {
    @Published private(set) var sources: [any FileSource] = []
    /// Pre-scan progress for SMB servers, keyed by source id.
    @Published private(set) var smbScans: [String: SMBScanProgress] = [:]

    private let bookmarkStore = BookmarkStore()
    private let smbStore = SMBServerStore()

    private let documentsSourceID = "local:documents"

    /// Builds the source list from persisted bookmarks and SMB configs.
    func loadPersisted() {
        var loaded: [any FileSource] = []

        #if !targetEnvironment(macCatalyst)
        // iOS/iPadOS: expose the app's Documents directory for AirDrop / Files.
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
        #endif

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

        // Pre-scan SMB folder structures so later browsing is instant.
        for source in sources where source is SMBFileSource {
            prewarm(source)
        }
    }

    func source(for id: String) -> (any FileSource)? {
        sources.first { $0.id == id }
    }

    // MARK: - SMB pre-scan

    /// Walks an SMB source's whole folder tree in the background to populate its
    /// listing cache, so later browsing is instant. Publishes progress.
    private func prewarm(_ source: any FileSource) {
        let id = source.id
        smbScans[id] = SMBScanProgress(isScanning: true, foldersScanned: 0)
        Task { @MainActor [weak self] in
            guard let self else { return }
            var scanned = 0
            var stack = [""]
            while let path = stack.popLast() {
                guard self.sources.contains(where: { $0.id == id }) else { break }   // source removed
                guard let items = try? await source.list(path: path) else { continue }
                scanned += 1
                self.smbScans[id]?.foldersScanned = scanned
                for item in items where item.kind == .directory {
                    stack.append(item.path)
                }
            }
            self.smbScans[id]?.isScanning = false
        }
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
        let source = SMBFileSource(config: config, password: password)
        sources.append(source)
        prewarm(source)   // learn the folder structure up front
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
        prewarm(updated)   // re-scan with the new settings
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
        smbScans[source.id] = nil
    }
}
