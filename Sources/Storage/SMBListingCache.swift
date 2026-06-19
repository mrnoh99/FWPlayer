import Foundation

/// On-disk cache of an SMB server's folder listings, so its structure survives
/// app restarts and browsing is instant after the one-time pre-scan.
///
/// Stored as one JSON file per server (keyed by the SMB config id) under
/// Application Support, which persists on the device (unlike Caches, which the
/// system may purge).
actor SMBListingCache {
    private let fileURL: URL
    private var entries: [String: [FileItem]]

    init(serverID: String) {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("SMBCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("\(serverID).json")

        if let data = try? Data(contentsOf: fileURL),
           let loaded = try? JSONDecoder().decode([String: [FileItem]].self, from: data) {
            self.entries = loaded
        } else {
            self.entries = [:]
        }
    }

    /// Cached listing for `path`, if present.
    func listing(path: String) -> [FileItem]? { entries[path] }

    /// Whether anything is cached at all (a pre-scan has run before).
    var isEmpty: Bool { entries.isEmpty }

    /// Stores a listing. Pass `persist: false` during a bulk scan and call
    /// `flush()` once at the end to avoid repeated disk writes.
    func store(path: String, items: [FileItem], persist: Bool = true) {
        entries[path] = items
        if persist { flush() }
    }

    func clear() {
        entries.removeAll()
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Writes the whole cache to disk.
    func flush() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
