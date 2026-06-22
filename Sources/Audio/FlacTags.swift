import Foundation

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
