import Foundation

// MARK: - FLAC decoding (pure Swift)
//
// A small FLAC decoder that reads through a `ByteSource`, so a FLAC file on an SMB share
// can be played from ranged reads while it downloads. It decodes frame by frame into
// float samples (exact for up to 24 bits) and supports seeking (SEEKTABLE when the file
// has one, otherwise a byte estimate refined by frame headers).
//
// Supported: 1–2 channels, 4–24 bits, any sample rate, all frame sizes, constant /
// verbatim / fixed / LPC subframes, 4- and 5-bit Rice residuals, all stereo modes.
// Not supported (the caller falls back to the old path): more than two channels and
// 32-bit audio. The logic was checked against ffmpeg-encoded files bit for bit.

struct FLACStreamInfo: Equatable {
    var minBlockSize: Int
    var maxBlockSize: Int
    var minFrameSize: Int
    var maxFrameSize: Int
    var sampleRate: Int
    var channels: Int
    var bitsPerSample: Int
    var totalSamples: UInt64
}

enum FLACError: LocalizedError {
    case notFLAC
    case unsupported(String)
    case corrupt(String)

    var errorDescription: String? {
        switch self {
        case .notFLAC: return "This isn't a FLAC file."
        case .unsupported(let why): return "Unsupported FLAC: \(why)."
        case .corrupt(let why): return "Damaged FLAC: \(why)."
        }
    }
}

/// MSB-first bit reader over a byte buffer. Reading past the end sets `overrun`
/// (and returns zeros) instead of trapping.
private struct BitReader {
    let base: UnsafePointer<UInt8>
    let count: Int
    var bitPos: Int
    var overrun = false

    init(base: UnsafePointer<UInt8>, count: Int, startByte: Int) {
        self.base = base
        self.count = count
        self.bitPos = startByte * 8
    }

    @inline(__always)
    mutating func bits(_ n: Int) -> UInt32 {
        if n == 0 { return 0 }
        let end = bitPos + n
        if end > count * 8 {
            overrun = true
            bitPos = end
            return 0
        }
        let byte = bitPos >> 3
        let shift = bitPos & 7
        let need = (shift + n + 7) >> 3
        var v: UInt64 = 0
        var i = 0
        while i < need {
            v = (v << 8) | UInt64(base[byte + i])
            i += 1
        }
        v >>= UInt64(need * 8 - shift - n)
        bitPos = end
        return UInt32(truncatingIfNeeded: v & ((UInt64(1) << UInt64(n)) - 1))
    }

    /// `n` bits as a two's-complement signed value (n ≥ 1).
    @inline(__always)
    mutating func signedBits(_ n: Int) -> Int32 {
        let v = bits(n)
        let shift = UInt32(32 - n)
        return Int32(bitPattern: v << shift) >> Int32(shift)
    }

    /// Number of zero bits before the next one bit.
    @inline(__always)
    mutating func unary() -> Int {
        var n = 0
        while true {
            if bitPos >= count * 8 {
                overrun = true
                return n
            }
            let bit = (base[bitPos >> 3] >> UInt8(7 - (bitPos & 7))) & 1
            bitPos += 1
            if bit == 1 { return n }
            n += 1
            if n > (1 << 24) { overrun = true; return n }
        }
    }

    mutating func alignToByte() { bitPos = (bitPos + 7) & ~7 }

    var bytePosition: Int { bitPos >> 3 }
}

private let crc8Table: [UInt8] = (0..<256).map { value -> UInt8 in
    var c = UInt8(value)
    for _ in 0..<8 { c = c & 0x80 != 0 ? (c << 1) ^ 0x07 : c << 1 }
    return c
}

private let crc16Table: [UInt16] = (0..<256).map { value -> UInt16 in
    var c = UInt16(value) << 8
    for _ in 0..<8 { c = c & 0x8000 != 0 ? (c << 1) ^ 0x8005 : c << 1 }
    return c
}

private struct FLACFrameHeader {
    var blockSize: Int
    var bitsPerSample: Int
    var assignment: Int            // 0…7 independent (assignment + 1 channels), 8 L/S, 9 S/R, 10 M/S
    var channels: Int
    var number: UInt64             // sample number (variable block size) or frame number
    var variableBlockSize: Bool
    var length: Int                // header length in bytes
}

final class FLACDecoder: @unchecked Sendable {
    let info: FLACStreamInfo
    /// Vorbis comments (keys upper-cased): ARTIST, ALBUM, TITLE, DATE, GENRE, …
    let tags: [String: String]
    /// The raw first PICTURE metadata block (cover art), if the file has one and it's
    /// under 8 MB. Parse it with `AlbumArtwork`.
    let pictureBlock: Data?

    var durationSeconds: Double {
        info.totalSamples > 0 ? Double(info.totalSamples) / Double(info.sampleRate) : 0
    }

    private let source: ByteSource
    private let fileSize: UInt64
    private let firstFrameOffset: UInt64
    private let seekPoints: [(sample: UInt64, offset: UInt64)]

    private var buffer = [UInt8]()
    private var bufferStart: UInt64          // file offset of buffer[0]
    private var cursor = 0                   // index of the next frame in `buffer`
    /// After a seek, leading samples of the next frame to drop.
    private var samplesToSkip = 0

    /// Reading ahead for a frame bigger than STREAMINFO promised stops here; beyond it the data is garbage.
    private static let maxFrameLookahead = 4 << 20

    /// Bytes needed in the buffer to decode any frame.
    private var neededBytes: Int {
        info.maxFrameSize > 0
            ? info.maxFrameSize + 32
            : info.maxBlockSize * info.channels * 4 + 4096
    }

    init(source: ByteSource) throws {
        self.source = source
        fileSize = source.size
        guard fileSize > 42, try source.read(at: 0, length: 4) == Data("fLaC".utf8) else { throw FLACError.notFLAC }

        var position: UInt64 = 4
        var streamInfo: FLACStreamInfo?
        var points = [(sample: UInt64, offset: UInt64)]()
        var comments = [String: String]()
        var picture: Data?
        var last = false
        while !last {
            let head = [UInt8](try source.read(at: position, length: 4))
            guard head.count == 4 else { throw FLACError.corrupt("metadata ends too early") }
            last = head[0] & 0x80 != 0
            let type = Int(head[0] & 0x7F)
            let length = Int(head[1]) << 16 | Int(head[2]) << 8 | Int(head[3])
            let body = position + 4
            switch type {
            case 0:
                let b = [UInt8](try source.read(at: body, length: 34))
                guard b.count == 34 else { throw FLACError.corrupt("short STREAMINFO") }
                let packed = b[10..<18].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
                streamInfo = FLACStreamInfo(
                    minBlockSize: Int(b[0]) << 8 | Int(b[1]),
                    maxBlockSize: Int(b[2]) << 8 | Int(b[3]),
                    minFrameSize: Int(b[4]) << 16 | Int(b[5]) << 8 | Int(b[6]),
                    maxFrameSize: Int(b[7]) << 16 | Int(b[8]) << 8 | Int(b[9]),
                    sampleRate: Int(packed >> 44),
                    channels: Int((packed >> 41) & 7) + 1,
                    bitsPerSample: Int((packed >> 36) & 31) + 1,
                    totalSamples: packed & ((UInt64(1) << 36) - 1))
            case 3:
                let b = [UInt8](try source.read(at: body, length: length))
                var i = 0
                while i + 18 <= b.count {
                    let sample = b[i..<(i + 8)].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
                    let offset = b[(i + 8)..<(i + 16)].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
                    if sample != UInt64.max { points.append((sample, offset)) }   // skip placeholders
                    i += 18
                }
            case 4:
                comments = Self.parseVorbisComments([UInt8](try source.read(at: body, length: min(length, 1 << 20))))
            case 6:
                if picture == nil, length > 32, length <= 8 << 20 {
                    picture = try? source.read(at: body, length: length)
                }
            default:
                break                                           // PADDING, …: skipped unread
            }
            position = body + UInt64(length)
        }
        guard let streamInfo else { throw FLACError.corrupt("no STREAMINFO") }
        guard streamInfo.sampleRate > 0, streamInfo.maxBlockSize > 0 else { throw FLACError.corrupt("bad STREAMINFO") }
        guard streamInfo.channels <= 2 else { throw FLACError.unsupported("more than two channels") }
        guard streamInfo.bitsPerSample <= 24 else { throw FLACError.unsupported("\(streamInfo.bitsPerSample)-bit audio") }

        info = streamInfo
        tags = comments
        pictureBlock = picture
        seekPoints = points.sorted { $0.sample < $1.sample }
        firstFrameOffset = position
        bufferStart = position
    }

    private static func parseVorbisComments(_ b: [UInt8]) -> [String: String] {
        func u32(_ o: Int) -> Int? {
            guard o + 4 <= b.count else { return nil }
            return Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 | Int(b[o + 3]) << 24
        }
        guard let vendor = u32(0), let count = u32(4 + vendor) else { return [:] }
        var offset = 8 + vendor
        var result = [String: String]()
        for _ in 0..<min(count, 512) {
            guard let length = u32(offset), offset + 4 + length <= b.count else { break }
            let text = String(decoding: b[(offset + 4)..<(offset + 4 + length)], as: UTF8.self)
            if let eq = text.firstIndex(of: "=") {
                let key = text[..<eq].uppercased()
                if result[key] == nil { result[key] = String(text[text.index(after: eq)...]) }
            }
            offset += 4 + length
        }
        return result
    }

    // MARK: Buffering

    private func fill(minBytes: Int) throws {
        if cursor > (1 << 20) {
            buffer.removeFirst(cursor)
            bufferStart += UInt64(cursor)
            cursor = 0
        }
        while buffer.count - cursor < minBytes {
            let at = bufferStart + UInt64(buffer.count)
            if at >= fileSize { break }
            let data = try source.read(at: at, length: max(256 * 1024, minBytes))
            if data.isEmpty { break }
            buffer.append(contentsOf: data)
        }
    }

    private var atEnd: Bool { bufferStart + UInt64(buffer.count) >= fileSize }

    // MARK: Decoding

    struct DecodedFrame {
        var samples: [Float]           // interleaved stereo (mono is duplicated)
        var frames: Int
        var startSample: UInt64?       // known for variable block sizes
        var length: Int                // bytes
        var crcOK = true               // the frame's CRC-16 matched its bytes
    }

    /// Frames whose stored CRC-16 didn't match their bytes (damaged data from the file, drive or share).
    private(set) var crcErrors = 0
    /// Frames that couldn't be decoded and were skipped over (each one is a gap in the sound).
    private(set) var skippedFrames = 0

    /// The next frame as interleaved stereo floats, or nil at the end of the stream.
    func nextSamples() throws -> [Float]? {
        while true {
            try fill(minBytes: neededBytes)
            guard cursor < buffer.count else { return nil }

            let info = self.info
            let at = cursor
            var needsMore = false
            let decoded = buffer.withUnsafeBufferPointer { p in
                Self.decodeFrame(p, at: at, info: info, needsMore: &needsMore)
            }
            if let decoded {
                if !decoded.crcOK {
                    crcErrors += 1
                    if crcErrors <= 5 || crcErrors % 100 == 0 {
                        DiagnosticsLog.log("flac", "frame CRC mismatch near byte \(bufferStart + UInt64(at)) (\(crcErrors) so far): damaged data")
                    }
                }
                cursor += decoded.length
                var samples = decoded.samples
                if samplesToSkip > 0 {
                    let drop = min(samplesToSkip, decoded.frames)
                    samples.removeFirst(drop * 2)
                    samplesToSkip -= drop
                }
                if samples.isEmpty { continue }
                return samples
            }
            // The frame runs past what was read (a bigger frame than STREAMINFO promised): read more.
            if needsMore && !atEnd && buffer.count - cursor < Self.maxFrameLookahead {
                let before = buffer.count
                try fill(minBytes: buffer.count - cursor + 256 * 1024)
                if buffer.count > before { continue }
            }
            // Lost sync or a damaged frame: look for the next valid frame header.
            skippedFrames += 1
            if skippedFrames <= 5 || skippedFrames % 100 == 0 {
                DiagnosticsLog.log("flac", "skipped an undecodable frame near byte \(bufferStart + UInt64(at)) (\(skippedFrames) so far)")
            }
            guard let next = findFrame(from: cursor + 1) else {
                if atEnd { return nil }
                cursor = max(cursor, buffer.count - 16)          // keep a tail so a split header is found
                try fill(minBytes: neededBytes)
                if buffer.count - cursor <= 16 && atEnd { return nil }
                continue
            }
            cursor = next
        }
    }

    /// The index of the next valid frame header at or after `start`, if the buffer has one.
    private func findFrame(from start: Int) -> Int? {
        let info = self.info
        return buffer.withUnsafeBufferPointer { p -> Int? in
            var i = max(start, 0)
            while i + 6 < p.count {
                if p[i] == 0xFF, p[i + 1] & 0xFE == 0xF8, Self.parseHeader(p, at: i, info: info) != nil { return i }
                i += 1
            }
            return nil
        }
    }

    // MARK: Frame header

    private static func parseHeader(_ p: UnsafeBufferPointer<UInt8>, at i: Int, info: FLACStreamInfo) -> FLACFrameHeader? {
        guard i + 6 <= p.count, p[i] == 0xFF, p[i + 1] & 0xFE == 0xF8 else { return nil }
        let variable = p[i + 1] & 1 == 1
        let blockCode = Int(p[i + 2] >> 4), rateCode = Int(p[i + 2] & 0x0F)
        let assignment = Int(p[i + 3] >> 4), sizeCode = Int((p[i + 3] >> 1) & 7)
        guard p[i + 3] & 1 == 0 else { return nil }

        var j = i + 4
        let first = p[j]
        var number = UInt64(first)
        if first >= 0x80 {
            var n = 0
            while n < 7, first & (UInt8(0x80) >> UInt8(n + 1)) != 0 { n += 1 }
            guard n >= 1, n <= 6, j + n < p.count else { return nil }
            number = UInt64(first & (UInt8(0x7F) >> UInt8(n + 1)))
            for k in 1...n {
                let b = p[j + k]
                guard b & 0xC0 == 0x80 else { return nil }
                number = (number << 6) | UInt64(b & 0x3F)
            }
            j += n
        }
        j += 1

        var blockSize: Int
        switch blockCode {
        case 0: return nil
        case 1: blockSize = 192
        case 2...5: blockSize = 576 << (blockCode - 2)
        case 6:
            guard j < p.count else { return nil }
            blockSize = Int(p[j]) + 1; j += 1
        case 7:
            guard j + 1 < p.count else { return nil }
            blockSize = (Int(p[j]) << 8 | Int(p[j + 1])) + 1; j += 2
        default: blockSize = 256 << (blockCode - 8)
        }
        switch rateCode {
        case 12: j += 1
        case 13, 14: j += 2
        case 15: return nil
        default: break
        }
        guard j < p.count else { return nil }

        var crc: UInt8 = 0
        for k in i..<j { crc = crc8Table[Int(crc ^ p[k])] }
        guard crc == p[j] else { return nil }

        let bps: Int
        switch sizeCode {
        case 0: bps = info.bitsPerSample
        case 1: bps = 8
        case 2: bps = 12
        case 4: bps = 16
        case 5: bps = 20
        case 6: bps = 24
        default: return nil                    // 3 is reserved; 32-bit isn't supported
        }
        let channels: Int
        switch assignment {
        case 0...7: channels = assignment + 1
        case 8...10: channels = 2
        default: return nil
        }
        guard channels <= 2, blockSize <= 65535 else { return nil }
        return FLACFrameHeader(blockSize: blockSize, bitsPerSample: bps, assignment: assignment,
                               channels: channels, number: number, variableBlockSize: variable,
                               length: j + 1 - i)
    }

    private static func decodeFrame(_ p: UnsafeBufferPointer<UInt8>, at i: Int, info: FLACStreamInfo,
                                    needsMore: inout Bool) -> DecodedFrame? {
        guard let header = parseHeader(p, at: i, info: info), let base = p.baseAddress else { return nil }
        var reader = BitReader(base: base, count: p.count, startByte: i + header.length)

        var channels = [[Int32]](repeating: [Int32](repeating: 0, count: header.blockSize), count: header.channels)
        for c in 0..<header.channels {
            var depth = header.bitsPerSample
            if (header.assignment == 8 && c == 1) || (header.assignment == 9 && c == 0) || (header.assignment == 10 && c == 1) {
                depth += 1                                      // the side channel has one more bit
            }
            guard decodeSubframe(&reader, blockSize: header.blockSize, bitsPerSample: depth, into: &channels[c]) else {
                needsMore = reader.overrun
                return nil
            }
        }
        reader.alignToByte()
        let crcEnd = reader.bytePosition
        let stored = UInt16(truncatingIfNeeded: reader.bits(16))
        if reader.overrun { needsMore = true; return nil }
        var crc: UInt16 = 0
        for k in i..<crcEnd { crc = (crc << 8) ^ crc16Table[Int((crc >> 8) ^ UInt16(p[k]))] }

        let n = header.blockSize
        switch header.assignment {
        case 8:                                                 // left / side
            for k in 0..<n { channels[1][k] = channels[0][k] &- channels[1][k] }
        case 9:                                                 // side / right
            for k in 0..<n { channels[0][k] = channels[0][k] &+ channels[1][k] }
        case 10:                                                // mid / side
            for k in 0..<n {
                let side = channels[1][k]
                let mid = (channels[0][k] << 1) | (side & 1)
                channels[0][k] = (mid &+ side) >> 1
                channels[1][k] = (mid &- side) >> 1
            }
        default: break
        }

        let scale = 1 / Float(Int64(1) << Int64(header.bitsPerSample - 1))
        var out = [Float](repeating: 0, count: n * 2)
        if header.channels == 1 {
            for k in 0..<n {
                let v = Float(channels[0][k]) * scale
                out[2 * k] = v
                out[2 * k + 1] = v
            }
        } else {
            for k in 0..<n {
                out[2 * k] = Float(channels[0][k]) * scale
                out[2 * k + 1] = Float(channels[1][k]) * scale
            }
        }
        let start: UInt64? = header.variableBlockSize ? header.number : nil
        return DecodedFrame(samples: out, frames: n, startSample: start, length: reader.bytePosition - i,
                            crcOK: crc == stored)
    }

    // MARK: Subframes

    private static func decodeSubframe(_ r: inout BitReader, blockSize: Int, bitsPerSample: Int,
                                       into out: inout [Int32]) -> Bool {
        _ = r.bits(1)
        let type = Int(r.bits(6))
        var wasted = 0
        if r.bits(1) == 1 { wasted = r.unary() + 1 }
        let depth = bitsPerSample - wasted
        guard depth > 0, depth <= 32, !r.overrun else { return false }

        switch type {
        case 0:
            let value = r.signedBits(depth)
            for k in 0..<blockSize { out[k] = value }
        case 1:
            for k in 0..<blockSize { out[k] = r.signedBits(depth) }
        case 8...15:
            let order = type & 7
            guard order <= 4, order <= blockSize else { return false }
            for k in 0..<order { out[k] = r.signedBits(depth) }
            var residual = [Int32](repeating: 0, count: blockSize - order)
            guard decodeResidual(&r, blockSize: blockSize, order: order, into: &residual) else { return false }
            for k in order..<blockSize {
                let r1 = order > 0 ? Int64(out[k - 1]) : 0, r2 = order > 1 ? Int64(out[k - 2]) : 0
                let r3 = order > 2 ? Int64(out[k - 3]) : 0, r4 = order > 3 ? Int64(out[k - 4]) : 0
                let prediction: Int64
                switch order {
                case 0: prediction = 0
                case 1: prediction = r1
                case 2: prediction = 2 * r1 - r2
                case 3: prediction = 3 * r1 - 3 * r2 + r3
                default: prediction = 4 * r1 - 6 * r2 + 4 * r3 - r4
                }
                out[k] = Int32(truncatingIfNeeded: prediction + Int64(residual[k - order]))
            }
        case 32...63:
            let order = (type & 31) + 1
            guard order <= blockSize else { return false }
            for k in 0..<order { out[k] = r.signedBits(depth) }
            let precisionBits = Int(r.bits(4))
            guard precisionBits != 15 else { return false }
            let precision = precisionBits + 1
            let shift = Int(r.signedBits(5))
            guard shift >= 0 else { return false }
            var coefficients = [Int64](repeating: 0, count: order)
            for j in 0..<order { coefficients[j] = Int64(r.signedBits(precision)) }
            var residual = [Int32](repeating: 0, count: blockSize - order)
            guard decodeResidual(&r, blockSize: blockSize, order: order, into: &residual) else { return false }
            out.withUnsafeMutableBufferPointer { s in
                coefficients.withUnsafeBufferPointer { c in
                    for k in order..<blockSize {
                        var sum: Int64 = 0
                        for j in 0..<order { sum += c[j] * Int64(s[k - 1 - j]) }
                        s[k] = Int32(truncatingIfNeeded: (sum >> Int64(shift)) + Int64(residual[k - order]))
                    }
                }
            }
        default:
            return false
        }
        if wasted > 0 {
            for k in 0..<blockSize { out[k] = out[k] << Int32(wasted) }
        }
        return !r.overrun
    }

    private static func decodeResidual(_ r: inout BitReader, blockSize: Int, order: Int,
                                       into residual: inout [Int32]) -> Bool {
        let method = Int(r.bits(2))
        guard method <= 1 else { return false }
        let partitionOrder = Int(r.bits(4))
        let partitions = 1 << partitionOrder
        guard blockSize % partitions == 0, (blockSize >> partitionOrder) >= order else { return false }
        let parameterBits = method == 0 ? 4 : 5
        var index = 0
        for partition in 0..<partitions {
            let n = (blockSize >> partitionOrder) - (partition == 0 ? order : 0)
            let parameter = Int(r.bits(parameterBits))
            if parameter == (1 << parameterBits) - 1 {          // escape: raw samples
                let raw = Int(r.bits(5))
                for _ in 0..<n {
                    residual[index] = raw == 0 ? 0 : r.signedBits(raw)
                    index += 1
                }
            } else {
                for _ in 0..<n {
                    let quotient = r.unary()
                    let low = parameter == 0 ? 0 : r.bits(parameter)
                    let value = (UInt32(truncatingIfNeeded: quotient) << UInt32(parameter)) | low
                    residual[index] = Int32(bitPattern: value >> 1) ^ Int32(bitPattern: 0 &- (value & 1))
                    index += 1
                }
            }
            if r.overrun { return false }
        }
        return true
    }

    // MARK: Seeking

    /// Positions the decoder at `seconds`: the next `nextSamples()` starts exactly there.
    func seek(toSeconds seconds: Double) throws {
        let total = info.totalSamples
        var target = UInt64(max(0, seconds) * Double(info.sampleRate))
        if total > 0, target >= total { target = total - 1 }

        var offset = firstFrameOffset
        if let point = seekPoints.last(where: { $0.sample <= target }) {
            offset = firstFrameOffset + point.offset
        } else if total > 0, target > 0 {
            let span = fileSize - firstFrameOffset
            offset = firstFrameOffset + UInt64(Double(target) / Double(total) * Double(span))
        }

        var attempts = 0
        while true {
            try position(at: offset)
            guard let found = try firstFrameStart(from: offset) else { break }
            if found.start <= target || offset <= firstFrameOffset || attempts >= 12 {
                // Decode forward, discarding whole frames before the target.
                cursor = found.index
                try skipFrames(until: target, firstKnownStart: found.start)
                return
            }
            // Overshot: step back in proportion to the miss and try again.
            let missSamples = found.start - target
            let bytesPerSample = max(1.0, Double(fileSize - firstFrameOffset) / Double(max(total, 1)))
            let back = UInt64(Double(missSamples) * bytesPerSample * 1.5) + 65536
            offset = offset > firstFrameOffset + back ? offset - back : firstFrameOffset
            attempts += 1
        }
        // Nothing found (end of file): behave as at the end of the stream.
        cursor = buffer.count
    }

    private func position(at offset: UInt64) throws {
        buffer.removeAll(keepingCapacity: true)
        bufferStart = offset
        cursor = 0
        samplesToSkip = 0
        try fill(minBytes: neededBytes)
    }

    /// Finds the first valid frame at or after the current buffer position and returns its
    /// index and starting sample (computed from the frame number for fixed block sizes).
    private func firstFrameStart(from offset: UInt64) throws -> (index: Int, start: UInt64)? {
        let info = self.info
        var searchFrom = 0
        while true {
            guard let index = findFrame(from: searchFrom) else {
                if atEnd { return nil }
                searchFrom = max(0, buffer.count - 16)
                try fill(minBytes: buffer.count + neededBytes)       // read further and retry
                if buffer.count - searchFrom <= 16 { return nil }
                continue
            }
            let header = buffer.withUnsafeBufferPointer { Self.parseHeader($0, at: index, info: info) }
            guard let header else { searchFrom = index + 1; continue }
            let start = header.variableBlockSize
                ? header.number
                : header.number * UInt64(info.maxBlockSize)
            return (index, start)
        }
    }

    /// Decodes forward from `cursor` (a frame starting at `firstKnownStart`) until the frame
    /// holding `target`, leaving `samplesToSkip` so the next frame returned starts at it.
    private func skipFrames(until target: UInt64, firstKnownStart: UInt64) throws {
        var frameStart = firstKnownStart
        let info = self.info
        while true {
            try fill(minBytes: neededBytes)
            guard cursor < buffer.count else { return }
            let at = cursor
            var needsMore = false
            let decoded = buffer.withUnsafeBufferPointer { Self.decodeFrame($0, at: at, info: info, needsMore: &needsMore) }
            guard let decoded else {
                if needsMore && !atEnd && buffer.count - cursor < Self.maxFrameLookahead {
                    let before = buffer.count
                    try fill(minBytes: buffer.count - cursor + 256 * 1024)
                    if buffer.count > before { continue }
                }
                guard let next = findFrame(from: cursor + 1) else { return }
                cursor = next
                continue
            }
            let frameEnd = frameStart + UInt64(decoded.frames)
            if frameEnd > target {
                samplesToSkip = target > frameStart ? Int(target - frameStart) : 0
                return                                          // leave this frame to be decoded by nextSamples()
            }
            cursor += decoded.length
            frameStart = decoded.startSample.map { $0 + UInt64(decoded.frames) } ?? frameEnd
        }
    }
}
