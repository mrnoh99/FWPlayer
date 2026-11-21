import Foundation

// MARK: - DSD (DSF / DFF) playback over DoP
//
// Core Audio can't play DSD files. DoP ("DSD over PCM", the open standard by
// dCS/Playback Designs) carries the 1-bit stream inside ordinary 24-bit PCM so a
// DSD-capable USB DAC can recover it bit-exactly:
//
//   * every 24-bit sample holds 16 consecutive DSD bits of one channel
//     (oldest bit first): bits 15…0 = DSD data, bits 23…16 = a marker byte;
//   * the marker alternates 0x05, 0xFA, 0x05, … on every frame, which is how the
//     DAC recognises DoP and tells it apart from real PCM;
//   * the PCM rate is the DSD rate / 16 (DSD64 → 176.4 kHz, DSD128 → 352.8 kHz).
//
// The file is converted to a temporary 24-bit WAV and played by AVAudioPlayer
// like any other track, so seeking, duration, queueing and Now Playing keep
// working. Bit-exactness requires unity gain and no sample-rate conversion, so
// the player locks its volume at 100% for these tracks and the system volume
// must be at maximum. DoP that isn't recognised (or is attenuated) plays as
// loud noise — see `AudioPlayer`'s guards.

struct DSDDoPDecoder: AudioDecoder {
    static let supportedExtensions: Set<String> = ["dsf", "dff"]
    static let producesDoP = true

    /// DSD sampling rates that map to a PCM rate the DAC accepts (≤ 384 kHz).
    private static func pcmRate(forDSDRate rate: Int) throws -> Int {
        switch rate {
        case 2_822_400: return 176_400     // DSD64
        case 5_644_800: return 352_800     // DSD128
        case 3_072_000: return 192_000     // DSD64, 48 kHz family
        case 6_144_000: return 384_000     // DSD128, 48 kHz family
        case 11_289_600, 12_288_000:
            throw AudioDecoderError.dsdUnsupported("DSD256 can't be sent as DoP (it would need a 705.6 kHz PCM carrier).")
        default:
            throw AudioDecoderError.dsdUnsupported("Unsupported DSD sampling rate (\(rate) Hz).")
        }
    }

    func decode(sourceURL: URL) throws -> URL {
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: sourceURL) } catch { throw AudioDecoderError.openFailed }
        defer { try? handle.close() }

        let reader: DSDStreamReader
        switch sourceURL.pathExtension.lowercased() {
        case "dsf": reader = try DSFReader(handle: handle)
        case "dff": reader = try DFFReader(handle: handle)
        default: throw AudioDecoderError.unsupported
        }
        guard reader.channels == 2 else {
            throw AudioDecoderError.dsdUnsupported("Only stereo DSD files are supported.")
        }
        let pcmRate = try Self.pcmRate(forDSDRate: reader.dsdRate)

        let writer = try WAVStreamWriter(sampleRate: pcmRate, channels: 2, bitsPerSample: 24)
        let encoder = DoPEncoder()
        do {
            while let chunk = try reader.next() {
                try writer.append(encoder.encode(left: chunk.left, right: chunk.right))
            }
            try writer.finish()
        } catch {
            writer.abort()
            throw error
        }
        return writer.url
    }
}

// MARK: - DoP encoding

/// Packs MSB-first DSD bytes into DoP frames (24-bit little-endian PCM).
private final class DoPEncoder {
    /// Alternates every frame, continuing across chunks.
    private var nextMarkerIsLow = true

    /// `left` / `right` hold the same, even number of bytes.
    func encode(left: [UInt8], right: [UInt8]) -> Data {
        let frames = min(left.count, right.count) / 2
        var out = [UInt8](repeating: 0, count: frames * 6)
        var lowMarker = nextMarkerIsLow
        left.withUnsafeBufferPointer { l in
            right.withUnsafeBufferPointer { r in
                out.withUnsafeMutableBufferPointer { o in
                    for f in 0..<frames {
                        let marker: UInt8 = lowMarker ? 0x05 : 0xFA
                        lowMarker.toggle()
                        let base = f * 6
                        // 24-bit little endian: low byte (newest DSD byte) first,
                        // marker in the top byte.
                        o[base]     = l[2 * f + 1]
                        o[base + 1] = l[2 * f]
                        o[base + 2] = marker
                        o[base + 3] = r[2 * f + 1]
                        o[base + 4] = r[2 * f]
                        o[base + 5] = marker
                    }
                }
            }
        }
        nextMarkerIsLow = lowMarker
        return Data(out)
    }
}

// MARK: - Container readers

/// A run of MSB-first DSD bytes for each channel; both arrays have the same,
/// even length.
private struct DSDChunk {
    var left: [UInt8]
    var right: [UInt8]
}

private protocol DSDStreamReader: AnyObject {
    var dsdRate: Int { get }
    var channels: Int { get }
    /// The next run of audio, or nil at the end of the stream.
    func next() throws -> DSDChunk?
}

/// DSD "silence" byte pattern, used to pad an odd trailing byte.
private let dsdSilenceByte: UInt8 = 0x69

private let bitReversed: [UInt8] = (0..<256).map { value -> UInt8 in
    var v = UInt8(value), r: UInt8 = 0
    for _ in 0..<8 { r = (r << 1) | (v & 1); v >>= 1 }
    return r
}

private func readExactly(_ handle: FileHandle, at offset: UInt64, count: Int) throws -> [UInt8] {
    do {
        try handle.seek(toOffset: offset)
        guard let data = try handle.read(upToCount: count), data.count == count else {
            throw AudioDecoderError.openFailed
        }
        return [UInt8](data)
    } catch let error as AudioDecoderError {
        throw error
    } catch {
        throw AudioDecoderError.openFailed
    }
}

private func le32(_ b: [UInt8], _ o: Int) -> UInt32 {
    UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
}
private func le64(_ b: [UInt8], _ o: Int) -> UInt64 {
    UInt64(le32(b, o)) | UInt64(le32(b, o + 4)) << 32
}
private func be16(_ b: [UInt8], _ o: Int) -> UInt16 { UInt16(b[o]) << 8 | UInt16(b[o + 1]) }
private func be32(_ b: [UInt8], _ o: Int) -> UInt32 {
    UInt32(b[o]) << 24 | UInt32(b[o + 1]) << 16 | UInt32(b[o + 2]) << 8 | UInt32(b[o + 3])
}
private func be64(_ b: [UInt8], _ o: Int) -> UInt64 { UInt64(be32(b, o)) << 32 | UInt64(be32(b, o + 4)) }
private func fourCC(_ b: [UInt8], _ o: Int) -> String {
    String(decoding: b[o..<(o + 4)], as: UTF8.self)
}

/// Sony DSF: little-endian chunks ("DSD ", "fmt ", "data"); audio is stored in
/// per-channel blocks (usually 4096 bytes), usually LSB-first.
private final class DSFReader: DSDStreamReader {
    let dsdRate: Int
    let channels: Int
    private let handle: FileHandle
    private let blockSize: Int
    private let lsbFirst: Bool
    private var dataOffset: UInt64
    private var groupsRemaining: Int
    private var bytesPerChannelRemaining: Int

    init(handle: FileHandle) throws {
        self.handle = handle
        let head = try readExactly(handle, at: 0, count: 28)
        guard fourCC(head, 0) == "DSD " else { throw AudioDecoderError.openFailed }
        let fileSize = try handle.seekToEnd()

        var fmt: [UInt8]?
        var dataStart: UInt64 = 0
        var dataLength: UInt64 = 0
        var offset: UInt64 = 28
        while offset + 12 <= fileSize {
            let chunkHead = try readExactly(handle, at: offset, count: 12)
            let id = fourCC(chunkHead, 0)
            let size = le64(chunkHead, 4)
            guard size >= 12, size <= fileSize else { throw AudioDecoderError.openFailed }
            if id == "fmt " {
                guard size >= 52 else { throw AudioDecoderError.openFailed }
                fmt = try readExactly(handle, at: offset + 12, count: 40)
            } else if id == "data" {
                dataStart = offset + 12
                dataLength = min(size - 12, fileSize - dataStart)
                break
            }
            offset += size
        }
        guard let fmt, dataStart > 0 else { throw AudioDecoderError.openFailed }

        // fmt body: version, formatID, channelType, channelNum, freq, bits, samples(8), blockSize, reserved
        guard le32(fmt, 4) == 0 else {                      // 0 = DSD raw
            throw AudioDecoderError.dsdUnsupported("Unsupported DSF format.")
        }
        let channelCount = Int(le32(fmt, 12))
        let block = Int(le32(fmt, 32))
        let sampleCount = le64(fmt, 24)
        guard channelCount > 0, block > 0, block % 2 == 0 else { throw AudioDecoderError.openFailed }

        channels = channelCount
        dsdRate = Int(le32(fmt, 16))
        lsbFirst = le32(fmt, 20) == 1
        blockSize = block
        dataOffset = dataStart
        groupsRemaining = Int(dataLength) / (block * channelCount)
        bytesPerChannelRemaining = Int(truncatingIfNeeded: (sampleCount &+ 7) / 8)
    }

    func next() throws -> DSDChunk? {
        guard channels == 2, groupsRemaining > 0, bytesPerChannelRemaining > 0 else { return nil }
        let groupBytes = blockSize * 2
        let groups = min(16, groupsRemaining)
        try handle.seek(toOffset: dataOffset)
        guard let data = try handle.read(upToCount: groups * groupBytes), data.count >= groupBytes else { return nil }
        let bytes = [UInt8](data)
        let groupsRead = bytes.count / groupBytes
        dataOffset += UInt64(groupsRead * groupBytes)
        groupsRemaining -= groupsRead

        var left = [UInt8](), right = [UInt8]()
        left.reserveCapacity(groupsRead * blockSize)
        right.reserveCapacity(groupsRead * blockSize)
        for g in 0..<groupsRead {
            let base = g * groupBytes
            left.append(contentsOf: bytes[base..<(base + blockSize)])
            right.append(contentsOf: bytes[(base + blockSize)..<(base + groupBytes)])
        }
        // The last block is zero-padded: keep only the real samples.
        let take = min(left.count, bytesPerChannelRemaining)
        bytesPerChannelRemaining -= take
        if take < left.count {
            left.removeSubrange(take...)
            right.removeSubrange(take...)
        }
        if lsbFirst {
            for i in left.indices { left[i] = bitReversed[Int(left[i])] }
            for i in right.indices { right[i] = bitReversed[Int(right[i])] }
        }
        if left.count % 2 == 1 {                            // DoP needs byte pairs
            left.append(dsdSilenceByte)
            right.append(dsdSilenceByte)
        }
        return DSDChunk(left: left, right: right)
    }
}

/// Philips DSDIFF ("FRM8", big-endian chunks); uncompressed DSD only, MSB-first,
/// channels interleaved byte by byte.
private final class DFFReader: DSDStreamReader {
    private(set) var dsdRate = 0
    private(set) var channels = 0
    private let handle: FileHandle
    private var dataOffset: UInt64 = 0
    private var dataRemaining: UInt64 = 0

    init(handle: FileHandle) throws {
        self.handle = handle
        let head = try readExactly(handle, at: 0, count: 16)
        guard fourCC(head, 0) == "FRM8", fourCC(head, 12) == "DSD " else { throw AudioDecoderError.openFailed }
        let fileSize = try handle.seekToEnd()

        var offset: UInt64 = 16
        var compressed = false
        while offset + 12 <= fileSize {
            let chunkHead = try readExactly(handle, at: offset, count: 12)
            let id = fourCC(chunkHead, 0)
            let size = be64(chunkHead, 4)
            guard size <= fileSize else { throw AudioDecoderError.openFailed }
            let body = offset + 12
            if id == "PROP", size >= 4, size < 1 << 20 {
                let prop = try readExactly(handle, at: body, count: Int(size))
                if fourCC(prop, 0) == "SND " {
                    var p = 4
                    while p + 12 <= prop.count {
                        let subID = fourCC(prop, p)
                        let subSize = Int(truncatingIfNeeded: be64(prop, p + 4))
                        let subBody = p + 12
                        guard subSize >= 0, subBody + subSize <= prop.count else { break }
                        switch subID {
                        case "FS  " where subSize >= 4: dsdRate = Int(be32(prop, subBody))
                        case "CHNL" where subSize >= 2: channels = Int(be16(prop, subBody))
                        case "CMPR" where subSize >= 4: compressed = fourCC(prop, subBody) != "DSD "
                        default: break
                        }
                        p = subBody + subSize + (subSize % 2)
                    }
                }
            } else if id == "DSD " {
                dataOffset = body
                dataRemaining = min(size, fileSize - body)
                break
            }
            offset = body + size + (size % 2)
        }
        guard !compressed else {
            throw AudioDecoderError.dsdUnsupported("Compressed DSD (DST) isn't supported.")
        }
        guard dsdRate > 0, channels > 0, dataOffset > 0 else { throw AudioDecoderError.openFailed }
    }

    func next() throws -> DSDChunk? {
        guard channels == 2, dataRemaining > 0 else { return nil }
        let perChannel = 16_384
        let want = min(UInt64(perChannel * 2), dataRemaining)
        try handle.seek(toOffset: dataOffset)
        guard let data = try handle.read(upToCount: Int(want)), data.count >= 2 else { return nil }
        let bytes = [UInt8](data)
        dataOffset += UInt64(bytes.count)
        dataRemaining -= UInt64(bytes.count)

        let frames = bytes.count / 2
        var left = [UInt8](repeating: 0, count: frames)
        var right = [UInt8](repeating: 0, count: frames)
        for i in 0..<frames {
            left[i] = bytes[2 * i]
            right[i] = bytes[2 * i + 1]
        }
        if frames % 2 == 1 {
            left.append(dsdSilenceByte)
            right.append(dsdSilenceByte)
        }
        return DSDChunk(left: left, right: right)
    }
}

// MARK: - Streaming WAV writer

/// Writes PCM to a temporary WAV file incrementally (DoP files are far too large
/// to build in memory) and patches the header sizes when finished.
final class WAVStreamWriter {
    let url: URL
    private let handle: FileHandle
    private let sampleRate: Int
    private let channels: Int
    private let bitsPerSample: Int
    private var dataBytes: UInt64 = 0

    init(sampleRate: Int, channels: Int, bitsPerSample: Int) throws {
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitsPerSample = bitsPerSample
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fwdecode-\(UUID().uuidString).wav")
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw AudioDecoderError.decodeFailed
        }
        handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: header(dataSize: 0))
    }

    func append(_ data: Data) throws {
        try handle.write(contentsOf: data)
        dataBytes += UInt64(data.count)
    }

    func finish() throws {
        guard dataBytes <= UInt64(UInt32.max) - 36 else { throw AudioDecoderError.decodeFailed }
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: header(dataSize: UInt32(dataBytes)))
        try handle.close()
    }

    /// Discards the partial file after a failure.
    func abort() {
        try? handle.close()
        try? FileManager.default.removeItem(at: url)
    }

    private func header(dataSize: UInt32) -> Data {
        let blockAlign = channels * bitsPerSample / 8
        var d = Data()
        func ascii(_ s: String) { d.append(contentsOf: Array(s.utf8)) }
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        ascii("RIFF"); u32(36 &+ dataSize); ascii("WAVE")
        ascii("fmt "); u32(16)
        u16(1); u16(UInt16(channels)); u32(UInt32(sampleRate)); u32(UInt32(sampleRate * blockAlign))
        u16(UInt16(blockAlign)); u16(UInt16(bitsPerSample))
        ascii("data"); u32(dataSize)
        return d
    }
}
