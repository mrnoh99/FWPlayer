import Foundation

// MARK: - Streamed PCM decoders

/// A decoder the live engine can pull interleaved stereo floats from, one chunk at a
/// time (FLAC, WAV, AIFF read through a `ByteSource`).
protocol StreamedPCMDecoder: AnyObject, Sendable {
    var sampleRate: Int { get }
    var durationSeconds: Double { get }
    /// Tags keyed by upper-cased name (ARTIST, ALBUM, DATE, GENRE, …); may be empty.
    var tags: [String: String] { get }
    /// A raw FLAC PICTURE block with cover art, if there is one.
    var pictureBlock: Data? { get }
    /// The next run of interleaved L,R samples, or nil at the end of the stream.
    func nextSamples() throws -> [Float]?
    func seek(toSeconds seconds: Double) throws
}

extension FLACDecoder: StreamedPCMDecoder {
    var sampleRate: Int { info.sampleRate }
}

/// Which file types play straight from a share, and how to open them.
enum StreamedPCM {
    static let extensions: Set<String> = ["flac", "wav", "aif", "aiff"]

    static func open(source: ByteSource, fileExtension ext: String) throws -> StreamedPCMDecoder {
        ext == "flac" ? try FLACDecoder(source: source) : try PCMFileDecoder(source: source)
    }

    static func label(forExtension ext: String) -> String {
        switch ext {
        case "flac": return "FLAC"
        case "wav": return "WAV"
        default: return "AIFF"
        }
    }
}

// MARK: - WAV / AIFF

enum PCMFileError: LocalizedError {
    case notSupported(String)

    var errorDescription: String? {
        switch self {
        case .notSupported(let why): return "Unsupported audio file: \(why)."
        }
    }
}

/// Uncompressed PCM in a WAV (RIFF) or AIFF / AIFF-C container: 8/16/24/32-bit integer
/// or 32-bit float, one or two channels. Samples are read straight from the file, so
/// seeking is a calculation and nothing is buffered beyond one chunk.
final class PCMFileDecoder: StreamedPCMDecoder, @unchecked Sendable {
    private enum Encoding { case uint8, int8, intLE, intBE, floatLE, floatBE }

    let sampleRate: Int
    let channels: Int
    let bitsPerSample: Int
    let tags: [String: String]
    var pictureBlock: Data? { nil }

    var durationSeconds: Double { Double(totalFrames) / Double(sampleRate) }

    private let source: ByteSource
    private let encoding: Encoding
    private let bytesPerSample: Int
    private let dataOffset: UInt64
    private let totalFrames: UInt64
    private var nextFrame: UInt64 = 0

    private static let framesPerChunk = 8192

    private var blockAlign: Int { bytesPerSample * channels }

    init(source: ByteSource) throws {
        self.source = source
        let size = source.size
        let head = [UInt8](try source.read(at: 0, length: 12))
        guard head.count == 12 else { throw PCMFileError.notSupported("file too short") }
        let tag = String(decoding: head[0..<4], as: UTF8.self)
        let form = String(decoding: head[8..<12], as: UTF8.self)
        let isWAV = tag == "RIFF" && form == "WAVE"
        let isAIFF = tag == "FORM" && (form == "AIFF" || form == "AIFC")
        guard isWAV || isAIFF else { throw PCMFileError.notSupported("not a WAV or AIFF file") }

        var rate = 0, channelCount = 0, bits = 0
        var enc: Encoding?
        var frames: UInt64?
        var dataStart: UInt64?
        var dataBytes: UInt64 = 0
        var tags = [String: String]()

        var position: UInt64 = 12
        var visited = 0
        while position + 8 <= size, visited < 64 {
            visited += 1
            let h = [UInt8](try source.read(at: position, length: 8))
            guard h.count == 8 else { break }
            let id = String(decoding: h[0..<4], as: UTF8.self)
            let length: UInt64 = isWAV
                ? UInt64(h[4]) | UInt64(h[5]) << 8 | UInt64(h[6]) << 16 | UInt64(h[7]) << 24
                : UInt64(h[7]) | UInt64(h[6]) << 8 | UInt64(h[5]) << 16 | UInt64(h[4]) << 24
            let body = position + 8
            let available = size > body ? size - body : 0

            if isWAV {
                switch id {
                case "fmt ":
                    let f = [UInt8](try source.read(at: body, length: Int(min(length, 40))))
                    guard f.count >= 16 else { throw PCMFileError.notSupported("short fmt chunk") }
                    var format = Int(f[0]) | Int(f[1]) << 8
                    channelCount = Int(f[2]) | Int(f[3]) << 8
                    rate = Int(f[4]) | Int(f[5]) << 8 | Int(f[6]) << 16 | Int(f[7]) << 24
                    bits = Int(f[14]) | Int(f[15]) << 8
                    if format == 0xFFFE, f.count >= 26 { format = Int(f[24]) | Int(f[25]) << 8 }
                    switch (format, bits) {
                    case (1, 8): enc = .uint8
                    case (1, 16), (1, 24), (1, 32): enc = .intLE
                    case (3, 32): enc = .floatLE
                    default: throw PCMFileError.notSupported("WAV format \(format) at \(bits) bits")
                    }
                case "data":
                    dataStart = body
                    dataBytes = (length == 0 || length == 0xFFFF_FFFF || length > available) ? available : length
                case "LIST":
                    Self.readInfoList(source: source, at: body, length: min(length, 65_536), into: &tags)
                default:
                    break
                }
            } else {
                switch id {
                case "COMM":
                    let c = [UInt8](try source.read(at: body, length: Int(min(length, 32))))
                    guard c.count >= 18 else { throw PCMFileError.notSupported("short COMM chunk") }
                    channelCount = Int(c[0]) << 8 | Int(c[1])
                    frames = UInt64(c[2]) << 24 | UInt64(c[3]) << 16 | UInt64(c[4]) << 8 | UInt64(c[5])
                    bits = Int(c[6]) << 8 | Int(c[7])
                    rate = Int(Self.extendedToDouble(Array(c[8..<18])).rounded())
                    var compression = "NONE"
                    if form == "AIFC", c.count >= 22 { compression = String(decoding: c[18..<22], as: UTF8.self) }
                    switch compression {
                    case "NONE", "twos": enc = bits == 8 ? .int8 : .intBE
                    case "sowt": enc = bits == 8 ? .int8 : .intLE
                    case "fl32", "FL32": enc = .floatBE
                    default: throw PCMFileError.notSupported("AIFF-C compression \(compression)")
                    }
                    if enc == .floatBE, bits != 32 { throw PCMFileError.notSupported("AIFF float at \(bits) bits") }
                case "SSND":
                    let s = [UInt8](try source.read(at: body, length: 8))
                    guard s.count == 8 else { throw PCMFileError.notSupported("short SSND chunk") }
                    let offset = UInt64(s[0]) << 24 | UInt64(s[1]) << 16 | UInt64(s[2]) << 8 | UInt64(s[3])
                    dataStart = body + 8 + offset
                    dataBytes = length > 8 + offset ? min(length - 8 - offset, available) : 0
                case "AUTH":
                    if let t = Self.readText(source: source, at: body, length: min(length, 512)) { tags["ARTIST"] = t }
                case "NAME":
                    if let t = Self.readText(source: source, at: body, length: min(length, 512)) { tags["TITLE"] = t }
                default:
                    break
                }
            }
            position = body + length + (length & 1)          // chunks are padded to an even size
        }

        guard let enc, let dataStart, rate > 0 else { throw PCMFileError.notSupported("no audio data") }
        guard (1...2).contains(channelCount) else { throw PCMFileError.notSupported("\(channelCount) channels") }
        guard [8, 16, 24, 32].contains(bits) else { throw PCMFileError.notSupported("\(bits)-bit audio") }

        self.encoding = enc
        self.sampleRate = rate
        self.channels = channelCount
        self.bitsPerSample = bits
        self.bytesPerSample = bits / 8
        self.dataOffset = dataStart
        let byAlign = dataBytes / UInt64(bits / 8 * channelCount)
        self.totalFrames = frames.map { min($0, byAlign) } ?? byAlign
        self.tags = tags
    }

    // MARK: Reading

    func nextSamples() throws -> [Float]? {
        guard nextFrame < totalFrames else { return nil }
        let wanted = Int(min(UInt64(Self.framesPerChunk), totalFrames - nextFrame))
        let data = try source.read(at: dataOffset + nextFrame * UInt64(blockAlign), length: wanted * blockAlign)
        let frames = data.count / blockAlign
        guard frames > 0 else {
            nextFrame = totalFrames                          // the file is shorter than it says
            return nil
        }
        nextFrame += UInt64(frames)
        return decode(data, frames: frames)
    }

    func seek(toSeconds seconds: Double) throws {
        let frame = UInt64(max(0, seconds) * Double(sampleRate))
        nextFrame = min(frame, totalFrames)
    }

    private func decode(_ data: Data, frames: Int) -> [Float] {
        var out = [Float](repeating: 0, count: frames * 2)
        data.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: UInt8.self)
            var i = 0
            for f in 0..<frames {
                let l = sample(p, i)
                i += bytesPerSample
                var r = l
                if channels == 2 {
                    r = sample(p, i)
                    i += bytesPerSample
                }
                out[2 * f] = l
                out[2 * f + 1] = r
            }
        }
        return out
    }

    @inline(__always)
    private func sample(_ p: UnsafeBufferPointer<UInt8>, _ i: Int) -> Float {
        switch (encoding, bytesPerSample) {
        case (.uint8, _):
            return (Float(p[i]) - 128) / 128
        case (.int8, _):
            return Float(Int8(bitPattern: p[i])) / 128
        case (.intLE, 2):
            return Float(Int16(bitPattern: UInt16(p[i]) | UInt16(p[i + 1]) << 8)) / 32768
        case (.intBE, 2):
            return Float(Int16(bitPattern: UInt16(p[i]) << 8 | UInt16(p[i + 1]))) / 32768
        case (.intLE, 3):
            var v = Int32(p[i]) | Int32(p[i + 1]) << 8 | Int32(p[i + 2]) << 16
            if v & 0x80_0000 != 0 { v -= 0x100_0000 }
            return Float(v) / 8_388_608
        case (.intBE, 3):
            var v = Int32(p[i]) << 16 | Int32(p[i + 1]) << 8 | Int32(p[i + 2])
            if v & 0x80_0000 != 0 { v -= 0x100_0000 }
            return Float(v) / 8_388_608
        case (.intLE, 4):
            let v = UInt32(p[i]) | UInt32(p[i + 1]) << 8 | UInt32(p[i + 2]) << 16 | UInt32(p[i + 3]) << 24
            return Float(Int32(bitPattern: v)) / 2_147_483_648
        case (.intBE, 4):
            let v = UInt32(p[i]) << 24 | UInt32(p[i + 1]) << 16 | UInt32(p[i + 2]) << 8 | UInt32(p[i + 3])
            return Float(Int32(bitPattern: v)) / 2_147_483_648
        case (.floatLE, 4):
            let v = UInt32(p[i]) | UInt32(p[i + 1]) << 8 | UInt32(p[i + 2]) << 16 | UInt32(p[i + 3]) << 24
            return Float(bitPattern: v)
        case (.floatBE, 4):
            let v = UInt32(p[i]) << 24 | UInt32(p[i + 1]) << 16 | UInt32(p[i + 2]) << 8 | UInt32(p[i + 3])
            return Float(bitPattern: v)
        default:
            return 0
        }
    }

    // MARK: Tags and helpers

    /// An 80-bit IEEE extended-precision number (AIFF sample rate) as a Double.
    private static func extendedToDouble(_ b: [UInt8]) -> Double {
        guard b.count == 10 else { return 0 }
        let exponent = Int(b[0] & 0x7F) << 8 | Int(b[1])
        var mantissa: UInt64 = 0
        for k in 2..<10 { mantissa = mantissa << 8 | UInt64(b[k]) }
        guard mantissa != 0 else { return 0 }
        let value = Double(mantissa) * pow(2.0, Double(exponent - 16383 - 63))
        return b[0] & 0x80 != 0 ? -value : value
    }

    private static func readText(source: ByteSource, at offset: UInt64, length: UInt64) -> String? {
        guard let data = try? source.read(at: offset, length: Int(length)), !data.isEmpty else { return nil }
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\0").union(.whitespacesAndNewlines))
        return text.isEmpty ? nil : text
    }

    /// RIFF `LIST` / `INFO` text fields (IART, IPRD, IGNR, ICRD, INAM).
    private static func readInfoList(source: ByteSource, at offset: UInt64, length: UInt64,
                                     into tags: inout [String: String]) {
        guard length >= 4, let data = try? source.read(at: offset, length: Int(length)) else { return }
        let b = [UInt8](data)
        guard String(decoding: b[0..<4], as: UTF8.self) == "INFO" else { return }
        var i = 4
        while i + 8 <= b.count {
            let id = String(decoding: b[i..<(i + 4)], as: UTF8.self)
            let size = Int(b[i + 4]) | Int(b[i + 5]) << 8 | Int(b[i + 6]) << 16 | Int(b[i + 7]) << 24
            let end = i + 8 + size
            guard end <= b.count else { break }
            let text = String(decoding: b[(i + 8)..<end], as: UTF8.self)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\0").union(.whitespacesAndNewlines))
            if !text.isEmpty {
                switch id {
                case "IART": tags["ARTIST"] = text
                case "IPRD": tags["ALBUM"] = text
                case "IGNR": tags["GENRE"] = text
                case "ICRD": tags["DATE"] = text
                case "INAM": tags["TITLE"] = text
                default: break
                }
            }
            i = end + (size & 1)
        }
    }
}
