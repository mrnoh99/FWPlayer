import Foundation

/// On-disk cache of folder listings for SMB servers and local library folders.
/// Browsing stays instant after a one-time pre-scan across app restarts.
actor FolderListingCache {
    private let fileURL: URL
    private var entries: [String: [FileItem]]

    init(subdirectory: String, sourceID: String) {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent(subdirectory, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // The cache only holds entries FWPlayer recognised as audio when it was built, so
        // it is keyed by the set of playable formats: adding a format (DSF/DFF, SACD
        // images, …) discards old caches and the library is scanned again — otherwise
        // files of the new format would never show up in already-cached folders.
        // (v3 → v4: also filtered hidden/AppleDouble files before; kept for history.)
        var fingerprint: UInt64 = 5381
        for byte in FileItem.audioExtensions.sorted().joined(separator: ",").utf8 {
            fingerprint = fingerprint &* 33 &+ UInt64(byte)
        }
        self.fileURL = dir.appendingPathComponent("\(sourceID)-v4-\(String(fingerprint, radix: 16)).json")
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(sourceID)-v3.json"))

        if let data = try? Data(contentsOf: fileURL),
           let loaded = try? JSONDecoder().decode([String: [FileItem]].self, from: data) {
            self.entries = loaded
        } else {
            self.entries = [:]
        }
    }

    func listing(path: String) -> [FileItem]? { entries[path] }

    var isEmpty: Bool { entries.isEmpty }

    func hasPlayableAudio(in path: String) -> Bool {
        ensurePlayabilityIndex()
        return subtreeHasAudio[path] ?? false
    }

    func subfolderHasPlayableAudio(in path: String) -> Bool {
        guard let listing = entries[path] else { return false }
        ensurePlayabilityIndex()
        for item in listing where item.kind == .directory {
            if subtreeHasAudio[item.path] == true { return true }
        }
        return false
    }

    func recursiveAudio(in path: String) -> [FileItem] {
        guard let listing = entries[path] else { return [] }
        var audio = listing.filter { $0.kind == .audio }
        for item in listing where item.kind == .directory {
            audio.append(contentsOf: recursiveAudio(in: item.path))
        }
        return audio.sorted {
            $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending
        }
    }

    private var subtreeHasAudio: [String: Bool] = [:]
    private var playabilityIndexed = false

    func computePlayabilityIndex() {
        subtreeHasAudio.removeAll()
        playabilityIndexed = false
        ensurePlayabilityIndex()
    }

    private func ensurePlayabilityIndex() {
        guard !playabilityIndexed else { return }
        let paths = entries.keys.sorted { $0.split(separator: "/").count > $1.split(separator: "/").count }
        for path in paths {
            let listing = entries[path] ?? []
            let hasDirect = listing.contains(where: { $0.kind == .audio })
            let hasInSubfolder = listing.contains(where: { item in
                item.kind == .directory && subtreeHasAudio[item.path] == true
            })
            subtreeHasAudio[path] = hasDirect || hasInSubfolder
        }
        playabilityIndexed = true
    }

    func store(path: String, items: [FileItem], persist: Bool = true) {
        entries[path] = items
        if persist { flush() }
    }

    func clear() {
        entries.removeAll()
        subtreeHasAudio.removeAll()
        playabilityIndexed = false
        try? FileManager.default.removeItem(at: fileURL)
    }

    func flush() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
