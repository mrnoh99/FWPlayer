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

/// How a DSD file is turned into something Core Audio can play.
enum DSDOutputMode {
    /// DSD over PCM: bit-exact, only for a USB DAC that recognises the markers.
    case dop
    /// Ordinary PCM (filtered and decimated), safe on any output.
    case pcm
}

/// The result of converting a DSD file.
struct DSDConversion {
    let url: URL
    /// True when `url` carries DoP rather than audio.
    let isDoP: Bool
    /// "DSD64", "DSD128", "DSD256" (plus " (48 kHz)" for the 48 kHz family).
    let label: String
}

struct DSDDoPDecoder: AudioDecoder {
    static let supportedExtensions: Set<String> = ["dsf", "dff"]
    static let producesDoP = true

    /// DoP files start and end with this much DSD silence, so the DAC has locked
    /// onto the DoP markers before the music begins and stays locked until after
    /// it ends (avoids a click at start/stop). `AudioPlayer` hides the offset.
    static let silenceSeconds: TimeInterval = 0.3

    func decode(sourceURL: URL) throws -> URL {
        try Self.convert(sourceURL: sourceURL, mode: .dop).url
    }

    /// Converts a DSF/DFF file to a temporary 24-bit WAV. `.dop` falls back to
    /// PCM for rates DoP can't carry (DSD256+ would need a 705.6 kHz carrier).
    static func convert(sourceURL: URL, mode: DSDOutputMode,
                        progress: (@Sendable (Double) -> Void)? = nil) throws -> DSDConversion {
        let reader = try makeReader(sourceURL: sourceURL)
        let chosen = try Self.plan(for: reader, mode: mode)
        let rate = chosen.dsdRate, multiple = chosen.multiple, useDoP = chosen.useDoP

        let writer = try WAVStreamWriter(sampleRate: chosen.outputRate, channels: 2, bitsPerSample: 24)
        do {
            if useDoP {
                let encoder = DoPEncoder()
                let silence = [UInt8](repeating: dsdSilenceByte,
                                      count: Int((Double(rate / 16) * silenceSeconds).rounded()) * 2)
                try writer.append(encoder.encode(left: silence, right: silence))
                var lastPercent = -1
                while let chunk = try reader.next() {
                    try writer.append(encoder.encode(left: chunk.left, right: chunk.right))
                    let percent = Int(reader.progress * 100)
                    if percent != lastPercent { lastPercent = percent; progress?(reader.progress) }
                }
                try writer.append(encoder.encode(left: silence, right: silence))
            } else {
                let converter = DSDToPCMConverter(dsdRate: rate, multiple: multiple)
                var lastPercent = -1
                while let chunk = try reader.next() {
                    try writer.append(converter.convert(left: chunk.left, right: chunk.right))
                    let percent = Int(reader.progress * 100)
                    if percent != lastPercent { lastPercent = percent; progress?(reader.progress) }
                }
            }
            try writer.finish()
        } catch {
            writer.abort()
            throw error
        }
        return DSDConversion(url: writer.url, isDoP: useDoP, label: chosen.label)
    }

    // MARK: Reader and plan (shared with live playback)

    /// Opens a DSF / DFF file, or one track of an SACD image (`disc.iso#track=N`).
    /// The reader keeps whatever it needs open until it is released.
    static func makeReader(sourceURL: URL) throws -> DSDStreamReader {
        let ext = sourceURL.pathExtension.lowercased()
        switch ext {
        case "dsf", "dff":
            let source: FileByteSource
            do { source = try FileByteSource(url: URL(fileURLWithPath: sourceURL.path)) }
            catch {
                // e.g. no access to the folder, or a file that isn't on the device yet (iCloud).
                throw AudioDecoderError.dsdUnsupported(
                    "Couldn't open \(sourceURL.lastPathComponent): \(error.localizedDescription)")
            }
            return try makeReader(stream: source, fileExtension: ext)
        case "iso":
            // One track of an SACD image: the track number rides in the URL fragment.
            let source = try SACDFileSectorSource(url: URL(fileURLWithPath: sourceURL.path))
            return try SACDTrackReader(source: source, trackNumber: SACDISOTrackURL.trackNumber(in: sourceURL))
        default:
            throw AudioDecoderError.unsupported
        }
    }

    /// A DSF / DFF reader over any byte source — a local file or a network stream.
    static func makeReader(stream: ByteSource, fileExtension ext: String) throws -> DSDStreamReader {
        let handle = ByteStreamHandle(stream)
        switch ext {
        case "dsf": return try DSFReader(handle: handle)
        case "dff": return try DFFReader(handle: handle)
        default: throw AudioDecoderError.unsupported
        }
    }

    /// How a stream is delivered: DoP or PCM, and at what rate.
    struct Plan {
        let dsdRate: Int
        let multiple: Int
        let useDoP: Bool
        /// Sample rate of the PCM that is produced (the DoP carrier, or 176.4 / 192 kHz).
        let outputRate: Int
        let label: String
    }

    static func plan(for reader: DSDStreamReader, mode: DSDOutputMode) throws -> Plan {
        guard reader.channels == 2 else {
            throw AudioDecoderError.dsdUnsupported("Only stereo DSD files are supported.")
        }
        // 44.1 kHz family (2.8224 MHz × m) or 48 kHz family (3.072 MHz × m).
        let rate = reader.dsdRate
        let family44 = rate % 2_822_400 == 0
        let family48 = rate % 3_072_000 == 0
        let multiple = family44 ? rate / 2_822_400 : (family48 ? rate / 3_072_000 : 0)
        // DSD64 … DSD1024. Only DSD64/128 can go out as DoP; the rest is converted to PCM.
        guard [1, 2, 4, 8, 16].contains(multiple) else {
            throw AudioDecoderError.dsdUnsupported("Unsupported DSD sampling rate (\(rate) Hz).")
        }
        let useDoP = mode == .dop && multiple <= 2
        return Plan(dsdRate: rate, multiple: multiple, useDoP: useDoP,
                    outputRate: useDoP ? rate / 16 : (family44 ? 176_400 : 192_000),
                    label: "DSD\(64 * multiple)" + (family48 ? " (48 kHz)" : ""))
    }
}

// MARK: - DSD → PCM (any output)
//
// For outputs that can't take DoP (speaker, Bluetooth, AirPlay, a non-DSD DAC) and
// for DSD256, the 1-bit stream is low-pass filtered and decimated to 176.4 kHz
// (192 kHz for the 48 kHz family), 24-bit. Two stages:
//   1. a Kaiser-window FIR evaluated with per-byte lookup tables (8 bits per
//      table lookup), decimating by 8·m down to 352.8 kHz (384 kHz);
//   2. a short float FIR decimating by 2.
// 0 dB on the SACD reference (50 % modulation) maps to PCM full scale (×2).

private func besselI0(_ x: Double) -> Double {
    var sum = 1.0, term = 1.0
    let q = x * x / 4
    var k = 1.0
    while term > 1e-12 * sum {
        term *= q / (k * k)
        sum += term
        k += 1
    }
    return sum
}

/// Kaiser-windowed-sinc low-pass; `cutoff` is normalised to the sampling rate
/// (0…0.5). Normalised to unity gain at DC.
private func kaiserLowpass(taps: Int, cutoff: Double, beta: Double) -> [Double] {
    let mid = Double(taps - 1) / 2
    var h = (0..<taps).map { n -> Double in
        let x = Double(n) - mid
        let sinc = x == 0 ? 2 * cutoff : sin(2 * Double.pi * cutoff * x) / (Double.pi * x)
        let r = mid > 0 ? x / mid : 0
        let window = besselI0(beta * (1 - r * r).squareRoot()) / besselI0(beta)
        return sinc * window
    }
    let sum = h.reduce(0, +)
    for i in h.indices { h[i] /= sum }
    return h
}

/// Stage 1 for one channel: 1-bit input, byte-wise table FIR.
private final class DSDDecimator {
    private let m: Int                // bytes consumed per output sample
    private let k: Int                // bytes spanned by the filter
    private let table: [Float]        // k × 256 partial sums
    private var state: [UInt8]        // last (k-1) bytes + not-yet-consumed bytes

    init(dsdRate: Int, multiple: Int) {
        let bytes = 10 * multiple     // 80·m taps
        m = multiple
        k = bytes
        let taps = 8 * bytes
        let h = kaiserLowpass(taps: taps, cutoff: 216_000 / Double(dsdRate), beta: 10)
        var t = [Float](repeating: 0, count: bytes * 256)
        for byteIndex in 0..<bytes {
            for value in 0..<256 {
                var sum = 0.0
                for i in 0..<8 {
                    // Bit i (0 = MSB = oldest) of the byte `byteIndex` back from the newest.
                    let coefficient = h[8 * byteIndex + (7 - i)]
                    sum += ((value >> (7 - i)) & 1) == 1 ? coefficient : -coefficient
                }
                t[byteIndex * 256 + value] = Float(sum * 2)      // ×2: SACD 0 dB → full scale
            }
        }
        table = t
        state = [UInt8](repeating: dsdSilenceByte, count: bytes - 1)
    }

    func process(_ input: [UInt8]) -> [Float] {
        var buf = state
        buf.append(contentsOf: input)
        let usable = max(0, (buf.count - (k - 1)) / m * m)
        let outCount = usable / m
        var out = [Float](repeating: 0, count: outCount)
        let k = self.k, m = self.m
        buf.withUnsafeBufferPointer { b in
            table.withUnsafeBufferPointer { t in
                out.withUnsafeMutableBufferPointer { o in
                    for j in 0..<outCount {
                        let p = (k - 1) + j * m + (m - 1)
                        var sum: Float = 0
                        for back in 0..<k {
                            sum += t[back * 256 + Int(b[p - back])]
                        }
                        o[j] = sum
                    }
                }
            }
        }
        state = Array(buf[usable...])
        return out
    }
}

/// Stage 2 for one channel: float FIR, decimate by 2.
private final class HalfBandDecimator {
    private let h: [Float]
    private var state: [Float]

    init() {
        let taps = 48
        h = kaiserLowpass(taps: taps, cutoff: 0.25, beta: 10).map { Float($0) }
        state = [Float](repeating: 0, count: taps - 1)
    }

    func process(_ input: [Float]) -> [Float] {
        let n = h.count
        var buf = state
        buf.append(contentsOf: input)
        let usable = max(0, (buf.count - (n - 1)) / 2 * 2)
        let outCount = usable / 2
        var out = [Float](repeating: 0, count: outCount)
        buf.withUnsafeBufferPointer { b in
            h.withUnsafeBufferPointer { c in
                out.withUnsafeMutableBufferPointer { o in
                    for j in 0..<outCount {
                        let p = (n - 1) + j * 2 + 1
                        var sum: Float = 0
                        for t in 0..<n { sum += c[t] * b[p - t] }
                        o[j] = sum
                    }
                }
            }
        }
        state = Array(buf[usable...])
        return out
    }
}

final class DSDToPCMConverter {
    private let stage1: (left: DSDDecimator, right: DSDDecimator)
    private let stage2: (left: HalfBandDecimator, right: HalfBandDecimator)

    init(dsdRate: Int, multiple: Int) {
        stage1 = (DSDDecimator(dsdRate: dsdRate, multiple: multiple),
                  DSDDecimator(dsdRate: dsdRate, multiple: multiple))
        stage2 = (HalfBandDecimator(), HalfBandDecimator())
    }

    /// Interleaved stereo float samples (clamped just inside ±1), for live playback.
    func convertToFloats(left: [UInt8], right: [UInt8]) -> [Float] {
        let l = stage2.left.process(stage1.left.process(left))
        let r = stage2.right.process(stage1.right.process(right))
        let frames = min(l.count, r.count)
        var out = [Float](repeating: 0, count: frames * 2)
        for f in 0..<frames {
            out[2 * f] = max(-0.99999, min(0.99999, l[f]))
            out[2 * f + 1] = max(-0.99999, min(0.99999, r[f]))
        }
        return out
    }

    /// Returns interleaved 24-bit little-endian stereo PCM.
    func convert(left: [UInt8], right: [UInt8]) -> Data {
        let l = stage2.left.process(stage1.left.process(left))
        let r = stage2.right.process(stage1.right.process(right))
        let frames = min(l.count, r.count)
        var out = [UInt8](repeating: 0, count: frames * 6)
        out.withUnsafeMutableBufferPointer { o in
            func put(_ value: Float, at base: Int) {
                let scaled = (Double(value) * 8_388_607).rounded()
                let v = Int32(max(-8_388_607, min(8_388_607, scaled)))
                o[base] = UInt8(truncatingIfNeeded: v)
                o[base + 1] = UInt8(truncatingIfNeeded: v >> 8)
                o[base + 2] = UInt8(truncatingIfNeeded: v >> 16)
            }
            for f in 0..<frames {
                put(l[f], at: f * 6)
                put(r[f], at: f * 6 + 3)
            }
        }
        return Data(out)
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
struct DSDChunk {
    var left: [UInt8]
    var right: [UInt8]
}

protocol DSDStreamReader: AnyObject, Sendable {
    var dsdRate: Int { get }
    var channels: Int { get }
    /// The next run of audio, or nil at the end of the stream.
    func next() throws -> DSDChunk?
    /// How much of the stream has been read, 0…1 (for progress display).
    var progress: Double { get }
    /// Length of the stream.
    var durationSeconds: Double { get }
    /// Repositions the stream (to an even byte boundary, which DoP needs).
    func seek(toSeconds seconds: Double) throws
}

/// DSD "silence" byte pattern, used to pad an odd trailing byte.
private let dsdSilenceByte: UInt8 = 0x69

private let bitReversed: [UInt8] = (0..<256).map { value -> UInt8 in
    var v = UInt8(value), r: UInt8 = 0
    for _ in 0..<8 { r = (r << 1) | (v & 1); v >>= 1 }
    return r
}

private func readExactly(_ handle: ByteStreamHandle, at offset: UInt64, count: Int) throws -> [UInt8] {
    do {
        try handle.seek(toOffset: offset)
        guard let data = try handle.read(upToCount: count), data.count == count else {
            throw AudioDecoderError.dsdUnsupported("The file ends too early to read its header (is the copy complete?).")
        }
        return [UInt8](data)
    } catch let error as AudioDecoderError {
        throw error
    } catch {
        throw AudioDecoderError.dsdUnsupported("Couldn't read the file (\(error.localizedDescription)).")
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
private final class DSFReader: DSDStreamReader, @unchecked Sendable {
    let dsdRate: Int
    let channels: Int
    private let handle: ByteStreamHandle
    private let blockSize: Int
    private let lsbFirst: Bool
    private var dataOffset: UInt64
    private var groupsRemaining: Int
    private let groupsTotal: Int
    private var bytesPerChannelRemaining: Int
    private let bytesPerChannelTotal: Int
    private let dataStart: UInt64
    /// Bytes at the start of the next chunk to drop after a seek.
    private var skipBytes = 0

    var durationSeconds: Double { Double(bytesPerChannelTotal) * 8 / Double(dsdRate) }

    deinit { try? handle.close() }

    func seek(toSeconds seconds: Double) throws {
        let evenTotal = bytesPerChannelTotal & ~1
        let wanted = min(evenTotal, max(0, Int(seconds * Double(dsdRate) / 8)) & ~1)
        let group = min(groupsTotal, wanted / blockSize)
        groupsRemaining = groupsTotal - group
        bytesPerChannelRemaining = bytesPerChannelTotal - group * blockSize
        dataOffset = dataStart + UInt64(group * blockSize * channels)
        skipBytes = wanted - group * blockSize
    }

    var progress: Double { groupsTotal > 0 ? 1 - Double(groupsRemaining) / Double(groupsTotal) : 1 }

    init(handle: ByteStreamHandle) throws {
        self.handle = handle
        let head = try readExactly(handle, at: 0, count: 28)
        func fail(_ why: String) -> AudioDecoderError { .dsdUnsupported("DSF file: \(why).") }
        guard fourCC(head, 0) == "DSD " else { throw fail("it doesn't start with a DSD header") }
        let fileSize = try handle.seekToEnd()

        var fmt: [UInt8]?
        var dataStart: UInt64 = 0
        var dataLength: UInt64 = 0
        var offset: UInt64 = 28
        while offset + 12 <= fileSize {
            let chunkHead = try readExactly(handle, at: offset, count: 12)
            let id = fourCC(chunkHead, 0)
            let size = le64(chunkHead, 4)
            guard size >= 12 else { throw fail("bad size \(size) for the '\(id)' chunk") }
            // (A data chunk larger than the file — a copy that isn't complete — is
            // played as far as it goes, so only other chunks must fit.)
            guard id == "data" || size <= fileSize else {
                throw fail("the '\(id)' chunk is larger than the file (is the copy complete?)")
            }
            if id == "fmt " {
                guard size >= 52 else { throw fail("the 'fmt ' chunk is too short (\(size) bytes)") }
                fmt = try readExactly(handle, at: offset + 12, count: 40)
            } else if id == "data" {
                dataStart = offset + 12
                dataLength = min(size - 12, fileSize - dataStart)
                break
            }
            offset += size
        }
        guard let fmt, dataStart > 0 else { throw fail("no 'fmt ' or 'data' chunk found (is the copy complete?)") }

        // fmt body: version, formatID, channelType, channelNum, freq, bits, samples(8), blockSize, reserved
        guard le32(fmt, 4) == 0 else {                      // 0 = DSD raw
            throw fail("unsupported format ID \(le32(fmt, 4))")
        }
        let channelCount = Int(le32(fmt, 12))
        let block = Int(le32(fmt, 32))
        let sampleCount = le64(fmt, 24)
        guard channelCount > 0, block > 0, block % 2 == 0 else {
            throw fail("unsupported layout (\(channelCount) channels, block size \(block))")
        }

        channels = channelCount
        dsdRate = Int(le32(fmt, 16))
        lsbFirst = le32(fmt, 20) == 1
        blockSize = block
        dataOffset = dataStart
        groupsRemaining = Int(dataLength) / (block * channelCount)
        groupsTotal = groupsRemaining
        guard groupsRemaining > 0 else { throw fail("no audio data in it (is the copy complete?)") }
        bytesPerChannelTotal = Int(truncatingIfNeeded: (sampleCount &+ 7) / 8)
        self.dataStart = dataStart
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
        if skipBytes > 0 {                                  // land mid-block after a seek
            let drop = min(skipBytes, left.count)
            left.removeFirst(drop)
            right.removeFirst(drop)
            bytesPerChannelRemaining -= drop
            skipBytes -= drop
        }
        // The last block is zero-padded: keep only the real samples.
        let take = min(left.count, bytesPerChannelRemaining)
        bytesPerChannelRemaining -= take
        if take < left.count {
            left.removeSubrange(take...)
            right.removeSubrange(take...)
        }
        if lsbFirst {
            // Hot loop: pointers instead of checked array indexing.
            bitReversed.withUnsafeBufferPointer { table in
                left.withUnsafeMutableBufferPointer { l in
                    for i in 0..<l.count { l[i] = table[Int(l[i])] }
                }
                right.withUnsafeMutableBufferPointer { r in
                    for i in 0..<r.count { r[i] = table[Int(r[i])] }
                }
            }
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
private final class DFFReader: DSDStreamReader, @unchecked Sendable {
    private(set) var dsdRate = 0
    private(set) var channels = 0
    private let handle: ByteStreamHandle
    private var dataOffset: UInt64 = 0
    private var dataRemaining: UInt64 = 0
    private var dataTotal: UInt64 = 0
    private var dataStart: UInt64 = 0

    var durationSeconds: Double { Double(dataTotal / UInt64(max(channels, 1))) * 8 / Double(max(dsdRate, 1)) }

    deinit { try? handle.close() }

    func seek(toSeconds seconds: Double) throws {
        let perChannel = Int(dataTotal) / max(channels, 1)
        let wanted = min(perChannel & ~1, max(0, Int(seconds * Double(dsdRate) / 8)) & ~1)
        dataOffset = dataStart + UInt64(wanted * channels)
        dataRemaining = dataTotal - UInt64(wanted * channels)
    }

    var progress: Double { dataTotal > 0 ? 1 - Double(dataRemaining) / Double(dataTotal) : 1 }

    init(handle: ByteStreamHandle) throws {
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
                dataTotal = dataRemaining
                dataStart = body
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

// MARK: - Tags (ID3v2 in DSF / DFF)

/// Reads the basic text tags (title, artist, album, date, genre) from the ID3v2
/// block that DSF files point to (and DFF files carry in an "ID3 " chunk).
enum DSDTags {
    /// Keys: TITLE, ARTIST, ALBUMARTIST, ALBUM, DATE, GENRE. Empty for non-DSD
    /// files or when there are no tags.
    static func read(from url: URL) -> [String: String] {
        let ext = url.pathExtension.lowercased()
        guard DSDDoPDecoder.supportedExtensions.contains(ext),
              let source = try? FileByteSource(url: url) else { return [:] }
        return read(from: source, fileExtension: ext)
    }

    /// The same, from any byte source (e.g. a file streamed from an SMB share).
    static func read(from source: ByteSource, fileExtension ext: String) -> [String: String] {
        guard DSDDoPDecoder.supportedExtensions.contains(ext) else { return [:] }
        let handle = ByteStreamHandle(source)
        let size = source.size

        var offset: UInt64 = 0
        if ext == "dsf" {
            guard let head = try? readExactly(handle, at: 0, count: 28), fourCC(head, 0) == "DSD " else { return [:] }
            offset = le64(head, 20)                    // metadata pointer
        } else {
            offset = dffID3Offset(handle, fileSize: size)
        }
        guard offset > 0, offset + 10 < size else { return [:] }
        return parseID3(handle, at: offset)
    }

    private static func dffID3Offset(_ handle: ByteStreamHandle, fileSize: UInt64) -> UInt64 {
        guard let head = try? readExactly(handle, at: 0, count: 16),
              fourCC(head, 0) == "FRM8" else { return 0 }
        var offset: UInt64 = 16
        while offset + 12 <= fileSize {
            guard let chunk = try? readExactly(handle, at: offset, count: 12) else { return 0 }
            let size = be64(chunk, 4)
            guard size <= fileSize else { return 0 }
            if fourCC(chunk, 0) == "ID3 " { return offset + 12 }
            offset += 12 + size + (size % 2)
        }
        return 0
    }

    private static func syncsafe(_ b: [UInt8], _ o: Int) -> Int {
        Int(b[o] & 0x7F) << 21 | Int(b[o + 1] & 0x7F) << 14 | Int(b[o + 2] & 0x7F) << 7 | Int(b[o + 3] & 0x7F)
    }

    private static func parseID3(_ handle: ByteStreamHandle, at offset: UInt64) -> [String: String] {
        guard let header = try? readExactly(handle, at: offset, count: 10),
              fourCC(header, 0).hasPrefix("ID3"),
              header[3] == 3 || header[3] == 4 else { return [:] }
        let version = Int(header[3])
        let tagSize = min(syncsafe(header, 6), 16 << 20)
        guard tagSize > 0, let tag = try? readExactly(handle, at: offset + 10, count: tagSize) else { return [:] }

        var pos = 0
        if header[5] & 0x40 != 0, tag.count >= 4 {          // extended header: skip it
            pos = version == 4 ? syncsafe(tag, 0) : Int(be32(tag, 0)) + 4
        }
        var result: [String: String] = [:]
        while pos >= 0, pos + 10 <= tag.count, tag[pos] != 0 {
            let id = fourCC(tag, pos)
            let size = version == 4 ? syncsafe(tag, pos + 4) : Int(be32(tag, pos + 4))
            let body = pos + 10
            guard size > 0, body + size <= tag.count else { break }
            if let key = mappedKey(id), let text = decodeText(Array(tag[body..<(body + size)])), !text.isEmpty,
               result[key] == nil {
                result[key] = text
            }
            pos = body + size
        }
        return result
    }

    private static func mappedKey(_ id: String) -> String? {
        switch id {
        case "TIT2": return "TITLE"
        case "TPE1": return "ARTIST"
        case "TPE2": return "ALBUMARTIST"
        case "TALB": return "ALBUM"
        case "TDRC", "TYER", "TDRL": return "DATE"
        case "TCON": return "GENRE"
        default: return nil
        }
    }

    /// ID3 text frame: an encoding byte, then the (possibly NUL-separated) text.
    private static func decodeText(_ frame: [UInt8]) -> String? {
        guard frame.count > 1 else { return nil }
        let payload = Data(frame[1...])
        let encoding: String.Encoding
        switch frame[0] {
        case 0: encoding = .isoLatin1
        case 1: encoding = .utf16
        case 2: encoding = .utf16BigEndian
        default: encoding = .utf8
        }
        guard let text = String(data: payload, encoding: encoding) else { return nil }
        let first = text.split(separator: "\u{0}", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        return first.trimmingCharacters(in: .whitespacesAndNewlines)
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
