import AVFoundation
import CryptoKit
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Resolves and caches album artwork through three layers, in order:
/// 1. artwork embedded in the audio file's metadata,
/// 2. a cover image sitting next to the file (cover.jpg / folder.jpg / …),
/// 3. an online lookup against the iTunes Search API.
///
/// Images are cached in memory and on disk (keyed by album, or by file when the
/// album is unknown) so each cover is fetched at most once.
@MainActor
final class ArtworkStore: ObservableObject {
    /// Bumped whenever a new image lands in the cache, so observing views re-read.
    @Published private(set) var generation = 0

    private var memory: [String: UIImage] = [:]
    private var inFlight: Set<String> = []
    private var missing: Set<String> = []
    private let diskDir: URL
    private let session = URLSession(configuration: .default)

    init() {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        diskDir = base.appendingPathComponent("Artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskDir, withIntermediateDirectories: true)
    }

    // MARK: - Keys

    /// Album-based key (shared by every track on the album), falling back to the
    /// track's own id when no album tag is present.
    static func key(for track: Track) -> String {
        if let album = track.album, !album.isEmpty {
            return "alb:\((track.artist ?? "").lowercased())\u{1}\(album.lowercased())"
        }
        return "file:\(track.id)"
    }

    // MARK: - Read (no side effects)

    func image(for track: Track) -> UIImage? { memory[Self.key(for: track)] }

    /// A downscaled JPEG of the track's artwork, for sending to remotes.
    func jpeg(for track: Track, maxDimension: CGFloat = 256, quality: CGFloat = 0.7) -> Data? {
        guard let image = memory[Self.key(for: track)] else { return nil }
        return image.fwDownscaled(to: maxDimension).jpegData(compressionQuality: quality)
    }

    // MARK: - Resolve for the playing track (we hold a real local file URL)

    func resolve(track: Track, fileURL: URL, folderURL: URL?) {
        let key = Self.key(for: track)
        guard memory[key] == nil, !inFlight.contains(key) else { return }
        if let disk = loadDisk(key) { cache(key, disk); return }
        inFlight.insert(key)
        let allowOnline = true
        Task { [session] in
            var data = await AlbumArtwork.embedded(from: fileURL)
            if data == nil, let folderURL { data = AlbumArtwork.sidecar(in: folderURL) }
            if data == nil, allowOnline {
                data = await AlbumArtwork.online(artist: track.artist, album: track.album, session: session)
            }
            await self.finish(key: key, data: data, maxDimension: 600)
        }
    }

    /// Best-effort artwork for a list row: embedded or sidecar from a directly
    /// readable (local) file. Skips the network to keep browsing cheap.
    func resolveLocalThumbnail(track: Track, directURL: URL?) {
        let key = Self.key(for: track)
        guard memory[key] == nil, !inFlight.contains(key), !missing.contains(key) else { return }
        if let disk = loadDisk(key) { cache(key, disk); return }
        guard let directURL else { return }
        inFlight.insert(key)
        Task {
            var data = await AlbumArtwork.embedded(from: directURL)
            if data == nil { data = AlbumArtwork.sidecar(in: directURL.deletingLastPathComponent()) }
            await self.finish(key: key, data: data, maxDimension: 300)
        }
    }

    private func finish(key: String, data: Data?, maxDimension: CGFloat) {
        inFlight.remove(key)
        guard let data, let image = UIImage(data: data) else { missing.insert(key); return }
        let scaled = image.fwDownscaled(to: maxDimension)
        cache(key, scaled)
        storeDisk(key, scaled)
    }

    private func cache(_ key: String, _ image: UIImage) {
        memory[key] = image
        generation &+= 1
    }

    // MARK: - Disk cache

    private func diskURL(_ key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return diskDir.appendingPathComponent("\(digest).jpg")
    }

    private func loadDisk(_ key: String) -> UIImage? {
        guard let data = try? Data(contentsOf: diskURL(key)) else { return nil }
        return UIImage(data: data)
    }

    private func storeDisk(_ key: String, _ image: UIImage) {
        guard let data = image.jpegData(compressionQuality: 0.85) else { return }
        try? data.write(to: diskURL(key), options: .atomic)
    }
}

// MARK: - Layered resolver

enum AlbumArtwork {
    /// Artwork embedded in the file's common metadata (ID3 APIC, MP4 covr,
    /// FLAC/Vorbis picture). Read via AVFoundation.
    static func embedded(from url: URL) async -> Data? {
        let asset = AVURLAsset(url: url)
        if let items = try? await asset.load(.commonMetadata) {
            for item in items where item.commonKey == .commonKeyArtwork {
                if let data = try? await item.load(.dataValue) { return data }
            }
        }
        // AVFoundation doesn't surface FLAC's embedded picture, so parse it directly.
        if url.pathExtension.lowercased() == "flac" {
            return flacPicture(from: url)
        }
        return nil
    }

    /// Extracts the image from a FLAC `METADATA_BLOCK_PICTURE`. Reads only the
    /// metadata header region (the picture block sits before the audio frames).
    static func flacPicture(from url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let magic = try? handle.read(upToCount: 4), magic == Data("fLaC".utf8) else { return nil }
        while true {
            guard let header = try? handle.read(upToCount: 4), header.count == 4 else { return nil }
            let h = [UInt8](header)
            let isLast = (h[0] & 0x80) != 0
            let type = h[0] & 0x7F
            let length = (Int(h[1]) << 16) | (Int(h[2]) << 8) | Int(h[3])
            if type == 6 {   // PICTURE
                guard let block = try? handle.read(upToCount: length), block.count == length else { return nil }
                return parseFlacPicture(block)
            }
            guard (try? handle.seek(toOffset: handle.offsetInFile + UInt64(length))) != nil else { return nil }
            if isLast { break }
        }
        return nil
    }

    private static func parseFlacPicture(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        var i = 0
        func u32() -> Int? {
            guard i + 4 <= bytes.count else { return nil }
            let v = (Int(bytes[i]) << 24) | (Int(bytes[i + 1]) << 16) | (Int(bytes[i + 2]) << 8) | Int(bytes[i + 3])
            i += 4
            return v
        }
        guard u32() != nil,                       // picture type
              let mimeLen = u32() else { return nil }
        i += mimeLen
        guard let descLen = u32() else { return nil }
        i += descLen
        guard u32() != nil, u32() != nil, u32() != nil, u32() != nil,   // width, height, depth, colors
              let dataLen = u32(), i + dataLen <= bytes.count else { return nil }
        return Data(bytes[i..<(i + dataLen)])
    }

    /// A cover image file living in the same folder as the track.
    static func sidecar(in folder: URL) -> Data? {
        let names = ["cover", "folder", "front", "album", "Cover", "Folder", "AlbumArt", "albumart"]
        let exts = ["jpg", "jpeg", "png"]
        for name in names {
            for ext in exts {
                let url = folder.appendingPathComponent("\(name).\(ext)")
                if let data = try? Data(contentsOf: url) { return data }
            }
        }
        return nil
    }

    /// iTunes Search API lookup by album (+ artist). Free, no key required.
    static func online(artist: String?, album: String?, session: URLSession) async -> Data? {
        guard let album, !album.isEmpty else { return nil }
        var term = album
        if let artist, !artist.isEmpty { term += " " + artist }
        guard let encoded = term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://itunes.apple.com/search?media=music&entity=album&limit=1&term=\(encoded)")
        else { return nil }
        guard let (data, _) = try? await session.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]],
              var artStr = results.first?["artworkUrl100"] as? String
        else { return nil }
        // Ask iTunes for a larger render than the 100×100 thumbnail it returns.
        artStr = artStr.replacingOccurrences(of: "100x100bb", with: "600x600bb")
        guard let artURL = URL(string: artStr),
              let (imageData, _) = try? await session.data(from: artURL) else { return nil }
        return imageData
    }
}

/// A small album-art thumbnail for list rows. Falls back to a music-note glyph,
/// and shows a now-playing badge for the current track. Triggers a best-effort
/// local artwork fetch when it appears.
struct ArtworkThumbnail: View {
    @EnvironmentObject private var artwork: ArtworkStore
    let track: Track
    let directURL: URL?
    var isCurrent: Bool = false
    var size: CGFloat = 38

    var body: some View {
        ZStack {
            if let image = artwork.image(for: track) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "music.note")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.secondary.opacity(0.12))
            }
            if isCurrent {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.caption2)
                    .foregroundStyle(.white)
                    .padding(3)
                    .background(.black.opacity(0.45), in: Circle())
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .task(id: directURL?.path) {
            artwork.resolveLocalThumbnail(track: track, directURL: directURL)
        }
    }
}

extension UIImage {
    /// Returns a copy whose longest side is at most `maxDimension` points.
    func fwDownscaled(to maxDimension: CGFloat) -> UIImage {
        let longest = max(size.width, size.height)
        guard longest > maxDimension, longest > 0 else { return self }
        let scale = maxDimension / longest
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in draw(in: CGRect(origin: .zero, size: newSize)) }
    }
}
