import AVFoundation
import Foundation

/// Reads lyrics embedded in an audio file's own tags. MusicKit's public API
/// doesn't expose catalog lyrics, so the file's tags are the reliable source:
/// ID3 `USLT` (MP3), iTunes `©lyr` (MP4/ALAC), and Vorbis `LYRICS` /
/// `UNSYNCEDLYRICS` comments (FLAC). Returns `nil` when none are present.
enum EmbeddedLyrics {
    static func read(from url: URL) async -> String? {
        if let viaAV = await fromAVMetadata(url: url), !viaAV.isEmpty { return viaAV }
        if url.pathExtension.lowercased() == "flac",
           let viaFlac = flacLyrics(from: url), !viaFlac.isEmpty { return viaFlac }
        return nil
    }

    /// ID3 / iTunes lyrics surfaced by AVFoundation.
    private static func fromAVMetadata(url: URL) async -> String? {
        let asset = AVURLAsset(url: url)
        guard let items = try? await asset.load(.metadata) else { return nil }
        let wanted: Set<AVMetadataIdentifier> = [
            .id3MetadataUnsynchronizedLyric,
            .iTunesMetadataLyrics
        ]
        for item in items where item.identifier.map({ wanted.contains($0) }) == true {
            if let value = try? await item.load(.stringValue), !value.isEmpty {
                return value
            }
        }
        return nil
    }

    /// Parses a FLAC `VORBIS_COMMENT` (metadata block type 4) for a lyrics field.
    /// Reads only the metadata header region (it precedes the audio frames).
    private static func flacLyrics(from url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let magic = try? handle.read(upToCount: 4), magic == Data("fLaC".utf8) else { return nil }
        while true {
            guard let header = try? handle.read(upToCount: 4), header.count == 4 else { return nil }
            let h = [UInt8](header)
            let isLast = (h[0] & 0x80) != 0
            let type = h[0] & 0x7F
            let length = (Int(h[1]) << 16) | (Int(h[2]) << 8) | Int(h[3])
            if type == 4 {   // VORBIS_COMMENT
                guard let block = try? handle.read(upToCount: length), block.count == length else { return nil }
                return parseVorbisLyrics(block)
            }
            guard (try? handle.seek(toOffset: handle.offsetInFile + UInt64(length))) != nil else { return nil }
            if isLast { break }
        }
        return nil
    }

    private static func parseVorbisLyrics(_ data: Data) -> String? {
        let bytes = [UInt8](data)
        var i = 0
        func u32le() -> Int? {
            guard i + 4 <= bytes.count else { return nil }
            let v = Int(bytes[i]) | (Int(bytes[i + 1]) << 8) | (Int(bytes[i + 2]) << 16) | (Int(bytes[i + 3]) << 24)
            i += 4
            return v
        }
        guard let vendorLen = u32le() else { return nil }
        i += vendorLen
        guard let count = u32le() else { return nil }
        let lyricKeys = ["LYRICS", "UNSYNCEDLYRICS", "UNSYNCED LYRICS"]
        for _ in 0..<count {
            guard let fieldLen = u32le(), i + fieldLen <= bytes.count else { return nil }
            let field = String(decoding: bytes[i..<(i + fieldLen)], as: UTF8.self)
            i += fieldLen
            if let eq = field.firstIndex(of: "=") {
                let key = field[..<eq].uppercased()
                if lyricKeys.contains(key) {
                    let value = String(field[field.index(after: eq)...])
                    if !value.isEmpty { return value }
                }
            }
        }
        return nil
    }
}

/// Reads FLAC Vorbis comments (ARTIST, ALBUM, DATE, GENRE, TITLE, …) directly.
/// AVFoundation doesn't surface these for FLAC via `commonMetadata`, so for a
/// FLAC library we parse the `VORBIS_COMMENT` metadata block ourselves (it sits
/// in the header, before the audio frames). Returns an empty map for non-FLAC
/// files or when no comment block is present.
enum FlacTags {
    /// Tag values keyed by uppercased field name (e.g. "ARTIST", "ALBUM").
    static func read(from url: URL) -> [String: String] {
        guard url.pathExtension.lowercased() == "flac",
              let handle = try? FileHandle(forReadingFrom: url) else { return [:] }
        defer { try? handle.close() }
        guard let magic = try? handle.read(upToCount: 4), magic == Data("fLaC".utf8) else { return [:] }
        while true {
            guard let header = try? handle.read(upToCount: 4), header.count == 4 else { return [:] }
            let h = [UInt8](header)
            let isLast = (h[0] & 0x80) != 0
            let type = h[0] & 0x7F
            let length = (Int(h[1]) << 16) | (Int(h[2]) << 8) | Int(h[3])
            if type == 4 {   // VORBIS_COMMENT
                guard let block = try? handle.read(upToCount: length), block.count == length else { return [:] }
                return parse(block)
            }
            guard (try? handle.seek(toOffset: handle.offsetInFile + UInt64(length))) != nil else { return [:] }
            if isLast { break }
        }
        return [:]
    }

    private static func parse(_ data: Data) -> [String: String] {
        let bytes = [UInt8](data)
        var i = 0
        func u32le() -> Int? {
            guard i + 4 <= bytes.count else { return nil }
            let v = Int(bytes[i]) | (Int(bytes[i + 1]) << 8) | (Int(bytes[i + 2]) << 16) | (Int(bytes[i + 3]) << 24)
            i += 4
            return v
        }
        var result: [String: String] = [:]
        guard let vendorLen = u32le() else { return result }
        i += vendorLen
        guard let count = u32le() else { return result }
        for _ in 0..<count {
            guard let len = u32le(), len >= 0, i + len <= bytes.count else { break }
            let field = String(decoding: bytes[i..<(i + len)], as: UTF8.self)
            i += len
            if let eq = field.firstIndex(of: "=") {
                let key = field[..<eq].uppercased()
                let value = String(field[field.index(after: eq)...])
                if result[key] == nil, !value.isEmpty { result[key] = value }
            }
        }
        return result
    }
}
