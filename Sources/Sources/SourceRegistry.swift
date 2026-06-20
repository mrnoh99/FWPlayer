import Foundation
import SwiftUI

/// Background pre-scan progress for a library source (SMB or local folder).
struct LibraryScanProgress: Equatable {
    var isScanning: Bool
    var foldersScanned: Int
}

/// Holds every active `FileSource` (the built-in Documents folder on iOS,
/// user-added local folders, and SMB servers) and owns their persistence.
@MainActor
final class SourceRegistry: ObservableObject {
    @Published private(set) var sources: [any FileSource] = []
    /// Pre-scan progress, keyed by source id.
    @Published private(set) var libraryScans: [String: LibraryScanProgress] = [:]

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

        #if targetEnvironment(macCatalyst)
        // Scan connected local folders that don't have a listing cache yet.
        for source in loaded {
            prewarm(source)
        }
        #endif
    }

    func source(for id: String) -> (any FileSource)? {
        sources.first { $0.id == id }
    }

    // MARK: - Library pre-scan

    /// Walks a source's folder tree once, caching listings for fast browsing.
    /// `force` clears and re-scans (used when SMB settings change).
    private func prewarm(_ source: any FileSource, force: Bool = false) {
        guard let scannable = source as? PrewarmableFileSource else { return }
        let id = source.id
        libraryScans[id] = LibraryScanProgress(isScanning: true, foldersScanned: 0)
        Task { [weak self] in
            let needsScan = await scannable.needsPrewarm()
            if !force && !needsScan {
                await MainActor.run { self?.libraryScans[id]?.isScanning = false }
                return
            }
            await scannable.prewarm { count in
                Task { @MainActor in
                    self?.libraryScans[id]?.foldersScanned = count
                }
            }
            await MainActor.run { self?.libraryScans[id]?.isScanning = false }
        }
    }

    // MARK: - Local folders

    func addLocalFolder(url: URL) throws {
        let bookmark = try BookmarkStore.makeBookmark(for: url)
        let id = "local:" + UUID().uuidString
        let name = url.lastPathComponent
        bookmarkStore.add(.init(id: id, displayName: name, bookmark: bookmark))
        let source = LocalFileSource(
            id: id,
            displayName: name,
            rootURL: url,
            kind: .localFolder,
            isSecurityScoped: true
        )
        sources.append(source)
        prewarm(source)
    }

    // MARK: - SMB servers

    func addSMBServer(_ config: SMBServerConfig, password: String) {
        smbStore.add(config, password: password)
        let source = SMBFileSource(config: config, password: password)
        sources.append(source)
        prewarm(source, force: true)
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
        prewarm(updated, force: true)
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
        libraryScans[source.id] = nil
    }
}
