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

    #if targetEnvironment(macCatalyst)
    /// Polls for audio CD insertion/ejection (Mac Catalyst can't observe the
    /// AppKit volume-mount notifications).
    private var cdPollTimer: Timer?
    /// Consecutive polls a known CD volume was missing from the mount list. A
    /// disc busy being ripped can momentarily drop out of the listing, so we
    /// only remove a CD source after it's been absent a couple of times rather
    /// than yanking the disc the user is actively playing.
    private var cdMissCounts: [String: Int] = [:]
    /// While true, the poll doesn't touch the optical drive. Set while a CD track
    /// is playing: probing the drive (even just for volume info) concurrently
    /// with AVAudioPlayer streaming a track causes read errors that make macOS
    /// eject the disc mid-song.
    private var cdWatchSuspended = false
    #endif

    /// Pauses/resumes audio-CD detection. The audio player suspends it while a CD
    /// track is playing so the drive isn't probed underneath the playback stream.
    func setCDWatchSuspended(_ suspended: Bool) {
        #if targetEnvironment(macCatalyst)
        cdWatchSuspended = suspended
        #endif
    }

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
        // Mac: pre-scan SMB shares so browsing stays fast; local folders are read
        // on demand (prewarm itself skips non-SMB sources).
        for source in loaded { prewarm(source) }
        // Detect any audio CD already inserted, and keep watching for changes.
        refreshAudioCDs()
        startAudioCDWatch()
        #endif
    }

    // MARK: - Audio CD (Mac Catalyst)

    #if targetEnvironment(macCatalyst)
    private func startAudioCDWatch() {
        guard cdPollTimer == nil else { return }
        let timer = Timer(timeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshAudioCDs() }
        }
        RunLoop.main.add(timer, forMode: .common)
        cdPollTimer = timer
    }

    /// Reconciles the source list with the audio CDs currently mounted: adds a
    /// source for a newly inserted disc and drops one that was ejected.
    func refreshAudioCDs() {
        // Don't probe the drive while a CD track is streaming — the concurrent
        // access ejects the disc.
        guard !cdWatchSuspended else { return }

        let mounted = CDAudioSource.mountedAudioCDVolumes()
        let mountedIDs = Set(mounted.map { "cd:" + $0.path })

        // Remove a CD source only after it's been missing from the mount list
        // for two consecutive polls, so a disc that briefly drops out while it's
        // being ripped isn't yanked mid-playback.
        var toRemove: Set<String> = []
        for source in sources where source.kind == .audioCD {
            if mountedIDs.contains(source.id) {
                cdMissCounts[source.id] = 0
            } else {
                let misses = (cdMissCounts[source.id] ?? 0) + 1
                cdMissCounts[source.id] = misses
                if misses >= 2 { toRemove.insert(source.id) }
            }
        }
        if !toRemove.isEmpty {
            sources.removeAll { toRemove.contains($0.id) }
            for id in toRemove { cdMissCounts[id] = nil }
        }

        // Add sources for newly mounted discs.
        let existingIDs = Set(sources.map { $0.id })
        for volume in mounted where !existingIDs.contains("cd:" + volume.path) {
            sources.append(CDAudioSource(volumeURL: volume))
            cdMissCounts["cd:" + volume.path] = 0
        }
    }
    #endif

    func source(for id: String) -> (any FileSource)? {
        sources.first { $0.id == id }
    }

    // MARK: - Library pre-scan

    /// Walks a source's folder tree once, caching listings for fast browsing.
    /// `force` clears and re-scans (used when SMB settings change).
    ///
    /// Policy: iOS / iPadOS never pre-scans (everything is read on demand). Mac
    /// Catalyst pre-scans SMB shares only, never local folders.
    private func prewarm(_ source: any FileSource, force: Bool = false) {
        #if targetEnvironment(macCatalyst)
        guard source.kind == .smb else { return }
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
        #endif
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
