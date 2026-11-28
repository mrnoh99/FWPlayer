import Foundation
#if canImport(CDST)
import CDST
#endif

// MARK: - SACD ISO (Scarlet Book) reading
//
// An SACD image is a sequence of 2048-byte logical sectors (LSN):
//
//   LSN 510            Master TOC ("SACDMTOC"), followed by 8 "SACDText" sectors
//                      and "SACD_Man"; it points at the Area TOCs;
//   Area TOC           "TWOCHTOC" (stereo) / "MULCHTOC" (multichannel): audio
//                      format, track range, then lists ("SACDTRL1" start/length in
//                      sectors, "SACDTRL2" times, "SACDTTxt" titles);
//   audio area         audio sectors: 1 header byte, N packet infos, M frame infos,
//                      then packets. A frame (1/75 s) is spread over packets and is
//                      either DST-compressed or raw DSD (4704 bytes per channel).
//
// Frames come out byte-interleaved by channel and MSB first — the same layout as a
// DSDIFF file — so the DoP / PCM pipeline treats a track like any other DSD stream.
//
// The structure follows SACD Ripper's libsacd (GPL v2; see Sources/DST/NOTICE.txt).
// Only decrypted images are supported, and only the stereo area is played.

enum SACDError: LocalizedError {
    case notAnSACD
    case unsupported(String)
    case readFailed
    case noSuchTrack(Int)
    case decodeFailed(String)

    var errorDescription: String? {
        switch self {
        case .notAnSACD: return "This isn't a (decrypted) SACD image."
        case .unsupported(let reason): return reason
        case .readFailed: return "Couldn't read the SACD image."
        case .noSuchTrack(let n): return "The SACD image has no track \(n)."
        case .decodeFailed(let reason): return "Couldn't decode the SACD audio (\(reason))."
        }
    }
}

/// Random access to the 2048-byte logical sectors of an image.
protocol SACDSectorSource: AnyObject {
    /// Reads `count` sectors starting at `lsn`; fewer bytes only at the end of the image.
    func readSectors(_ lsn: Int, count: Int) throws -> [UInt8]
}

/// Sector access to an image over any byte source (a local file or a network stream).
final class SACDByteSectorSource: SACDSectorSource, @unchecked Sendable {
    private let source: ByteSource

    init(source: ByteSource) { self.source = source }

    func readSectors(_ lsn: Int, count: Int) throws -> [UInt8] {
        guard lsn >= 0, count > 0 else { throw SACDError.readFailed }
        do {
            return [UInt8](try source.read(at: UInt64(lsn) * UInt64(SACDISO.sectorSize),
                                           length: count * SACDISO.sectorSize))
        } catch {
            throw SACDError.readFailed
        }
    }
}

/// Sector access to an image stored in a local file.
final class SACDFileSectorSource: SACDSectorSource {
    static let sectorSize = 2048
    private let handle: FileHandle

    init(url: URL) throws {
        do { handle = try FileHandle(forReadingFrom: url) } catch { throw SACDError.readFailed }
    }

    deinit { try? handle.close() }

    func readSectors(_ lsn: Int, count: Int) throws -> [UInt8] {
        guard lsn >= 0, count > 0 else { throw SACDError.readFailed }
        do {
            try handle.seek(toOffset: UInt64(lsn) * UInt64(Self.sectorSize))
            return [UInt8](try handle.read(upToCount: count * Self.sectorSize) ?? Data())
        } catch {
            throw SACDError.readFailed
        }
    }
}

/// A sector source backed by sector ranges already fetched into memory (e.g. the TOC
/// of a remote image read with a few ranged reads).
final class SACDMemorySectorSource: SACDSectorSource {
    private(set) var segments: [(lsn: Int, bytes: [UInt8])] = []

    func add(lsn: Int, bytes: [UInt8]) { segments.append((lsn, bytes)) }

    func readSectors(_ lsn: Int, count: Int) throws -> [UInt8] {
        let size = SACDISO.sectorSize
        for segment in segments where lsn >= segment.lsn {
            let start = (lsn - segment.lsn) * size
            let end = start + count * size
            if end <= segment.bytes.count { return Array(segment.bytes[start..<end]) }
        }
        throw SACDError.readFailed
    }
}

/// Reads just the table-of-contents sectors of an image through an async ranged
/// reader (`read(lsn, sectorCount)`), so a remote image needn't be downloaded to
/// list or play a track.
enum SACDTOCPrefetch {
    static func load(read: (Int, Int) async throws -> [UInt8]) async throws -> SACDMemorySectorSource {
        let master = try await read(SACDISO.masterTOCSector, 10)
        guard master.count >= 10 * SACDISO.sectorSize,
              String(decoding: master[0..<8], as: UTF8.self) == "SACDMTOC" else { throw SACDError.notAnSACD }
        let memory = SACDMemorySectorSource()
        memory.add(lsn: SACDISO.masterTOCSector, bytes: master)
        for location in SACDISO.areaTOCLocations(master: master) {
            for lsn in [location.toc1, location.toc2] where lsn > 0 {
                if let bytes = try? await read(lsn, location.sectors), bytes.count >= location.sectors * SACDISO.sectorSize {
                    memory.add(lsn: lsn, bytes: bytes)
                }
            }
        }
        return memory
    }
}

// MARK: - Virtual paths

/// How an image's tracks appear in a file browser: the `.iso` is shown as a folder
/// whose entries are `NN Title.sacdtrack`.
enum SACDVirtualPath {
    static let trackExtension = "sacdtrack"

    static func isImage(_ path: String) -> Bool {
        (path as NSString).pathExtension.lowercased() == "iso"
    }

    static func trackName(number: Int, title: String?) -> String {
        let cleaned = (title ?? "")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let shortened = String(cleaned.prefix(80))
        let prefix = String(format: "%02d", number)
        return (shortened.isEmpty ? "Track " + prefix : prefix + " " + shortened) + "." + trackExtension
    }

    /// `("dir/disc.iso", 3)` for `dir/disc.iso/03 Title.sacdtrack`.
    static func split(_ path: String) -> (image: String, track: Int)? {
        let ns = path as NSString
        guard ns.pathExtension.lowercased() == trackExtension else { return nil }
        let image = ns.deletingLastPathComponent
        guard isImage(image) else { return nil }
        // "03 Title" or "Track 03": the track number is the first run of digits.
        let name = ns.lastPathComponent
        guard let start = name.firstIndex(where: { $0.isASCII && $0.isNumber }) else { return nil }
        let digits = name[start...].prefix { $0.isASCII && $0.isNumber }
        guard let number = Int(digits), number > 0 else { return nil }
        return (image, number)
    }
}

struct SACDTrack: Equatable {
    var number: Int                 // 1-based
    var startLSN: Int
    var lengthLSN: Int
    /// Duration from the time table (0 when absent).
    var durationSeconds: Double
    var title: String?
    var performer: String?
}

struct SACDArea {
    var channels: Int
    /// 0 = DST, 2/3 = uncompressed DSD ("3 in 14" / "3 in 16").
    var frameFormat: Int
    var tracks: [SACDTrack]
    var isDST: Bool { frameFormat == 0 }
}

struct SACDDisc {
    var albumTitle: String?
    var albumArtist: String?
    /// The stereo area, if the disc has one.
    var stereo: SACDArea?
    var multichannel: SACDArea?
}

enum SACDISO {
    static let sectorSize = 2048
    static let masterTOCSector = 510
    static let framesPerSecond = 75.0
    /// Bytes of one channel in one frame (588 samples × 64 / 8).
    static let frameBytesPerChannel = 4704

    // MARK: Big-endian helpers

    private static func be16(_ b: [UInt8], _ o: Int) -> Int { Int(b[o]) << 8 | Int(b[o + 1]) }
    private static func be32(_ b: [UInt8], _ o: Int) -> Int {
        Int(b[o]) << 24 | Int(b[o + 1]) << 16 | Int(b[o + 2]) << 8 | Int(b[o + 3])
    }
    private static func id(_ b: [UInt8], _ o: Int) -> String {
        String(decoding: b[o..<(o + 8)], as: UTF8.self)
    }

    // MARK: Text

    /// Text encoding for the disc's `character_set` code.
    static func encoding(forCharacterSet code: Int) -> String.Encoding {
        switch code & 7 {
        case 3: return .shiftJIS                                   // Music Shift-JIS (RIS-506)
        case 4: return cfEncoding(.EUC_KR)                         // KSC 5601
        case 5: return cfEncoding(.GB_18030_2000)                  // GB 2312
        case 6: return cfEncoding(.big5)
        case 1: return .ascii                                       // ISO 646
        default: return .isoLatin1                                  // ISO 8859-1 (2, 7) / unknown
        }
    }

    private static func cfEncoding(_ e: CFStringEncodings) -> String.Encoding {
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(e.rawValue)))
    }

    /// Decodes disc text; if one stray byte makes the declared encoding reject it, tries
    /// the other common encodings instead of losing the whole string.
    private static func decode(_ bytes: [UInt8], encoding: String.Encoding) -> String {
        for candidate in [encoding, .shiftJIS, .japaneseEUC, .utf8, .isoLatin1] {
            if let text = String(bytes: bytes, encoding: candidate), !text.isEmpty { return text }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// The NUL-terminated string at `offset` (≤ 255 bytes), or nil when empty.
    private static func cString(_ b: [UInt8], at offset: Int, encoding: String.Encoding) -> String? {
        guard offset > 0, offset < b.count else { return nil }
        var end = offset
        while end < b.count, b[end] != 0, end - offset < 255 { end += 1 }
        guard end > offset else { return nil }
        // Some discs contain stray control characters in titles; blank them.
        let bytes = b[offset..<end].map { $0 < 0x20 ? UInt8(0x20) : $0 }
        let text = decode(bytes, encoding: encoding).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    // MARK: Disc structure

    /// Reads the Master TOC and Area TOCs.
    static func open(_ source: SACDSectorSource) throws -> SACDDisc {
        let master = try source.readSectors(masterTOCSector, count: 10)
        guard master.count >= 10 * sectorSize, id(master, 0) == "SACDMTOC" else { throw SACDError.notAnSACD }
        guard master[8] <= 1, master[9] <= 20 else {
            throw SACDError.unsupported("Unsupported Scarlet Book version \(master[8]).\(master[9]).")
        }

        let area1Toc1 = be32(master, 64), area1Toc2 = be32(master, 68), area1Size = be16(master, 84)
        let area2Toc1 = be32(master, 72), area2Toc2 = be32(master, 76), area2Size = be16(master, 86)
        let masterCharset = Int(master[136 + 2])                    // locales[0].character_set

        var disc = SACDDisc()
        let text = Array(master[sectorSize..<(2 * sectorSize)])    // first "SACDText" sector
        if id(text, 0) == "SACDText" {
            let enc = encoding(forCharacterSet: masterCharset)
            disc.albumTitle = cString(text, at: be16(text, 16) > 0 ? be16(text, 16) : 0, encoding: enc)
                ?? cString(text, at: be16(text, 32) > 0 ? be16(text, 32) : 0, encoding: enc)
            disc.albumArtist = cString(text, at: be16(text, 18) > 0 ? be16(text, 18) : 0, encoding: enc)
                ?? cString(text, at: be16(text, 34) > 0 ? be16(text, 34) : 0, encoding: enc)
        }

        for (toc1, toc2, size) in [(area1Toc1, area1Toc2, area1Size), (area2Toc1, area2Toc2, area2Size)]
        where toc1 > 0 && size > 0 {
            var data = (try? source.readSectors(toc1, count: size)) ?? []
            if data.count < size * sectorSize, toc2 > 0 {           // fall back to the backup TOC
                data = (try? source.readSectors(toc2, count: size)) ?? []
            }
            guard data.count >= size * sectorSize, let area = try parseAreaTOC(data) else { continue }
            if area.channels == 2 {
                if disc.stereo == nil { disc.stereo = area }
            } else if disc.multichannel == nil {
                disc.multichannel = area
            }
        }
        guard disc.stereo != nil || disc.multichannel != nil else { throw SACDError.notAnSACD }
        return disc
    }

    /// Where the Area TOCs (and their backups) live, per the Master TOC.
    static func areaTOCLocations(master: [UInt8]) -> [(toc1: Int, toc2: Int, sectors: Int)] {
        guard master.count >= 88 else { return [] }
        return [
            (be32(master, 64), be32(master, 68), be16(master, 84)),
            (be32(master, 72), be32(master, 76), be16(master, 86)),
        ].filter { $0.0 > 0 && $0.2 > 0 && $0.2 <= 96 }
    }

    private static func parseAreaTOC(_ data: [UInt8]) throws -> SACDArea? {
        let tocID = id(data, 0)
        guard tocID == "TWOCHTOC" || tocID == "MULCHTOC" else { return nil }
        guard data[8] <= 1, data[9] <= 20 else {
            throw SACDError.unsupported("Unsupported Scarlet Book version \(data[8]).\(data[9]).")
        }
        let tocSectors = be16(data, 10)
        let frameFormat = Int(data[21] & 0x0F)
        let channels = Int(data[32])
        let trackCount = Int(data[69])
        guard trackCount > 0, trackCount <= 255, channels > 0 else { return nil }

        var starts = [Int](repeating: 0, count: trackCount)
        var lengths = [Int](repeating: 0, count: trackCount)
        var durations = [Double](repeating: 0, count: trackCount)
        var titles = [String?](repeating: nil, count: trackCount)
        var performers = [String?](repeating: nil, count: trackCount)

        // Sectors after the first hold the lists, each tagged with an 8-byte id.
        var sector = 1
        var textSectors = 0
        while sector < min(tocSectors, data.count / sectorSize) {
            let base = sector * sectorSize
            let sectorID = String(decoding: data[base..<(base + 8)], as: UTF8.self)
            switch sectorID {
            case "SACDTTxt":
                do {                                                 // one per language; the first with a title wins
                    let languageIndex = min(textSectors, 9)
                    let enc = encoding(forCharacterSet: Int(data[88 + 4 * languageIndex + 2]))
                    textSectors += 1
                    // Track text positions are offsets from the start of this sector and
                    // often point into the sectors that follow it, so keep the rest of
                    // the TOC rather than one sector.
                    let slice = Array(data[base...])
                    for t in 0..<trackCount {
                        let position = be16(slice, 8 + 2 * t)
                        guard position > 0, position < slice.count else { continue }
                        var p = position
                        let amount = Int(slice[p])
                        p += 4
                        for j in 0..<amount {
                            guard p + 2 < slice.count else { break }
                            let type = slice[p]
                            p += 2                                    // type + a reserved byte
                            let value = cString(slice, at: p, encoding: enc)
                            if value != nil {
                                if type == 0x01, titles[t] == nil { titles[t] = value }
                                if type == 0x02, performers[t] == nil { performers[t] = value }
                            }
                            if j < amount - 1 {
                                while p < slice.count, slice[p] != 0 { p += 1 }
                                while p < slice.count, slice[p] == 0 { p += 1 }
                            }
                        }
                    }
                }
                sector += 1
            case "SACD_IGL": sector += 2
            case "SACD_ACC": sector += 32
            case "SACDTRL1":
                let slice = Array(data[base..<(base + sectorSize)])
                for t in 0..<trackCount {
                    starts[t] = be32(slice, 8 + 4 * t)
                    lengths[t] = be32(slice, 8 + 4 * 255 + 4 * t)
                }
                sector += 1
            case "SACDTRL2":
                let slice = Array(data[base..<(base + sectorSize)])
                for t in 0..<trackCount {
                    let o = 8 + 4 * 255 + 4 * t                      // duration[t]: min, sec, frames, flags
                    durations[t] = Double(Int(slice[o]) * 60 + Int(slice[o + 1])) + Double(slice[o + 2]) / framesPerSecond
                }
                sector += 1
            default:
                sector += 1          // text continuation or an unknown list: keep scanning for the ids
            }
        }

        let tracks = (0..<trackCount).compactMap { t -> SACDTrack? in
            guard starts[t] > 0, lengths[t] > 0 else { return nil }
            return SACDTrack(number: t + 1, startLSN: starts[t], lengthLSN: lengths[t],
                             durationSeconds: durations[t], title: titles[t], performer: performers[t])
        }
        guard !tracks.isEmpty else { return nil }
        return SACDArea(channels: channels, frameFormat: frameFormat, tracks: tracks)
    }
}

// MARK: - Track URLs

/// `…/disc.iso#track=3`: a file URL addressing one track of an SACD image.
enum SACDISOTrackURL {
    static func make(_ imageURL: URL, track: Int) -> URL {
        var components = URLComponents(url: imageURL, resolvingAgainstBaseURL: false)
        components?.fragment = "track=\(track)"
        return components?.url ?? imageURL
    }

    static func trackNumber(in url: URL) -> Int {
        guard let fragment = url.fragment, fragment.hasPrefix("track="),
              let n = Int(fragment.dropFirst("track=".count)), n > 0 else { return 1 }
        return n
    }
}

// MARK: - Frame extraction

/// Reassembles audio frames from the packets of consecutive audio sectors (the
/// logic of SACD Ripper's `scarletbook_process_frames`).
final class SACDFrameAssembler {
    private let channels: Int
    private var frame = [UInt8]()
    private var started = false
    private var dst = false
    private var sectorCount = 0
    private var frameChannels = 2

    init(channels: Int) { self.channels = channels }

    private func isComplete() -> Bool {
        guard started, !frame.isEmpty else { return false }
        return dst ? sectorCount == 0 : frame.count == frameChannels * SACDISO.frameBytesPerChannel
    }

    /// Feeds one 2048-byte audio sector; completed frames go to `emit` (DST-coded or raw).
    func process(sector s: ArraySlice<UInt8>, emit: ([UInt8], Bool) throws -> Void) throws {
        let base = s.startIndex
        func byte(_ i: Int) -> UInt8 { s[base + i] }

        let header = byte(0)
        let packetCount = Int((header >> 5) & 7)
        let frameInfoCount = Int((header >> 2) & 7)
        let sectorIsDST = header & 1 == 1
        guard packetCount <= 7 else { started = false; return }

        var pos = 1
        var packets = [(frameStart: Bool, type: Int, length: Int)]()
        for _ in 0..<packetCount {
            guard pos + 1 < SACDISO.sectorSize else { started = false; return }
            let b0 = byte(pos), b1 = byte(pos + 1)
            packets.append((frameStart: (b0 >> 7) & 1 == 1, type: Int((b0 >> 3) & 7),
                            length: Int(b0 & 7) << 8 | Int(b1)))
            pos += 2
        }
        // Per-frame info: timecode (3 bytes) plus, for DST, a byte with the channel
        // bits and the number of sectors the frame spans.
        var frameInfos = [(sectors: Int, channels: Int)]()
        for _ in 0..<frameInfoCount {
            let size = sectorIsDST ? 4 : 3
            guard pos + size <= SACDISO.sectorSize else { started = false; return }
            var sectors = 0, ch = 2
            if sectorIsDST {
                let flags = byte(pos + 3)
                sectors = Int((flags >> 2) & 0x1F)
                let bit2 = (flags >> 1) & 1, bit3 = flags & 1
                ch = bit2 == 1 && bit3 == 0 ? 6 : (bit2 == 0 && bit3 == 1 ? 5 : 2)
            }
            frameInfos.append((sectors, ch))
            pos += size
        }

        var infoIndex = 0
        for packet in packets {
            guard packet.length <= 2045, pos + packet.length <= SACDISO.sectorSize else { started = false; return }
            if packet.type == 2 {                                   // audio
                if packet.frameStart {
                    if isComplete() { try emit(frame, dst) }
                    guard infoIndex < frameInfos.count else { started = false; return }
                    frame.removeAll(keepingCapacity: true)
                    dst = sectorIsDST
                    sectorCount = frameInfos[infoIndex].sectors
                    frameChannels = sectorIsDST ? channels : frameInfos[infoIndex].channels
                    started = true
                    infoIndex += 1
                }
                if started {
                    if frame.count + packet.length <= 64 * 1024 {
                        frame.append(contentsOf: s[(base + pos)..<(base + pos + packet.length)])
                        if dst { sectorCount -= 1 }
                    } else {
                        started = false                              // corrupt: wait for the next frame
                    }
                }
            }                                                        // supplementary / padding: skipped
            pos += packet.length
        }
    }

    /// Emits the frame in progress (call after the last sector of a track).
    func finish(emit: ([UInt8], Bool) throws -> Void) throws {
        if isComplete() { try emit(frame, dst) }
        frame.removeAll()
        started = false
    }
}

// MARK: - Track → DSD stream

/// Streams one stereo track of an SACD image as byte-interleaved-then-split DSD
/// (MSB first), ready for the DoP / PCM pipeline.
final class SACDTrackReader: DSDStreamReader, @unchecked Sendable {
    let dsdRate = 2_822_400
    let channels = 2

    private let source: SACDSectorSource
    private let track: SACDTrack
    private let area: SACDArea
    private var assembler: SACDFrameAssembler
    private var nextSector: Int
    /// Frames to discard (undecoded) after a seek; the image has no time index here,
    /// so a seek re-reads the track from its start and skips ahead.
    private var framesToSkip = 0

    var durationSeconds: Double { track.durationSeconds }

    func seek(toSeconds seconds: Double) throws {
        nextSector = track.startLSN
        assembler = SACDFrameAssembler(channels: area.channels)
        pending.removeAll()
        finished = false
        framesToSkip = max(0, Int(seconds * SACDISO.framesPerSecond))
    }
    private let endSector: Int
    private var finished = false
    private var frameNumber = 0
    private var pending = [[UInt8]]()                                // decoded frames (interleaved)

    var progress: Double {
        let total = endSector - track.startLSN
        return total > 0 ? min(1, Double(nextSector - track.startLSN) / Double(total)) : 1
    }
    #if canImport(CDST) || FWDST_BRIDGED
    private var dstDecoder: OpaquePointer?
    #endif

    /// Sectors fetched per read (1 MB).
    private static let chunkSectors = 512
    /// Frames returned per `next()` call.
    private static let framesPerChunk = 16

    init(source: SACDSectorSource, trackNumber: Int) throws {
        self.source = source
        let disc = try SACDISO.open(source)
        guard let area = disc.stereo else {
            throw SACDError.unsupported("This SACD has no stereo area (multichannel isn't supported).")
        }
        guard let track = area.tracks.first(where: { $0.number == trackNumber }) else {
            throw SACDError.noSuchTrack(trackNumber)
        }
        guard area.frameFormat == 0 || area.frameFormat == 2 || area.frameFormat == 3 else {
            throw SACDError.unsupported("Unknown SACD frame format \(area.frameFormat).")
        }
        self.area = area
        self.track = track
        assembler = SACDFrameAssembler(channels: area.channels)
        nextSector = track.startLSN
        endSector = track.startLSN + track.lengthLSN
    }

    deinit {
        #if canImport(CDST) || FWDST_BRIDGED
        if let dstDecoder { fwdst_destroy(dstDecoder) }
        #endif
    }

    // MARK: Decoding

    private func decode(frame: [UInt8], isDST: Bool) throws -> [UInt8] {
        let expected = SACDISO.frameBytesPerChannel * 2
        if !isDST {
            guard frame.count == expected else { throw SACDError.decodeFailed("short DSD frame") }
            return frame
        }
        #if canImport(CDST) || FWDST_BRIDGED
        if dstDecoder == nil {
            guard let decoder = fwdst_create(Int32(area.channels)) else { throw SACDError.decodeFailed("DST decoder") }
            dstDecoder = decoder
        }
        var out = [UInt8](repeating: 0, count: expected)
        let status = frame.withUnsafeBufferPointer { input in
            out.withUnsafeMutableBufferPointer { output in
                fwdst_decode(dstDecoder, input.baseAddress, Int32(frame.count), Int32(frameNumber), output.baseAddress)
            }
        }
        frameNumber += 1
        guard status == 0 else {
            throw SACDError.decodeFailed(String(cString: fwdst_error_message(status)))
        }
        return out
        #else
        throw SACDError.unsupported("DST decoding isn't available in this build.")
        #endif
    }

    private func fillPending(upTo count: Int) throws {
        while pending.count < count, !finished {
            if nextSector >= endSector {
                try assembler.finish { frame, isDST in
                    if framesToSkip > 0 { framesToSkip -= 1; return }
                    pending.append(try decode(frame: frame, isDST: isDST))
                }
                finished = true
                break
            }
            let sectors = min(Self.chunkSectors, endSector - nextSector)
            let data = try source.readSectors(nextSector, count: sectors)
            guard data.count >= SACDISO.sectorSize else { finished = true; break }
            let whole = data.count / SACDISO.sectorSize
            for s in 0..<whole {
                let slice = data[(s * SACDISO.sectorSize)..<((s + 1) * SACDISO.sectorSize)]
                try assembler.process(sector: slice) { frame, isDST in
                    if framesToSkip > 0 { framesToSkip -= 1; return }
                    pending.append(try decode(frame: frame, isDST: isDST))
                }
            }
            nextSector += whole
        }
    }

    func next() throws -> DSDChunk? {
        try fillPending(upTo: Self.framesPerChunk)
        guard !pending.isEmpty else { return nil }
        let take = min(Self.framesPerChunk, pending.count)
        var left = [UInt8](), right = [UInt8]()
        left.reserveCapacity(take * SACDISO.frameBytesPerChannel)
        right.reserveCapacity(take * SACDISO.frameBytesPerChannel)
        for frame in pending.prefix(take) {
            var i = 0
            while i + 1 < frame.count {
                left.append(frame[i])
                right.append(frame[i + 1])
                i += 2
            }
        }
        pending.removeFirst(take)
        return DSDChunk(left: left, right: right)
    }
}
