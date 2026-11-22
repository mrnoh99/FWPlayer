import XCTest
@testable import FWPlayerCore
#if canImport(CDST)
import CDST
#endif

/// Tests for SACD image (Scarlet Book) reading, using a small synthetic image with
/// uncompressed DSD frames. (DST decoding needs real discs.)
final class SACDISOTests: XCTestCase {

    // MARK: - Synthetic image

    private let sectorSize = 2048
    private let frameBytes = 4704 * 2                       // one stereo frame, byte-interleaved

    private func be16(_ v: Int) -> [UInt8] { [UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
    private func be32(_ v: Int) -> [UInt8] {
        [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }
    private func put(_ sector: inout [UInt8], _ offset: Int, _ bytes: [UInt8]) {
        for (i, b) in bytes.enumerated() { sector[offset + i] = b }
    }
    private func ascii(_ s: String) -> [UInt8] { Array(s.utf8) }
    private func blank() -> [UInt8] { [UInt8](repeating: 0, count: sectorSize) }

    /// Deterministic content of one frame: left byte i of frame f of a track.
    private func left(track: Int, frame: Int, index: Int) -> UInt8 { UInt8((track * 53 + frame * 31 + index) & 0xFF) }
    private func right(track: Int, frame: Int, index: Int) -> UInt8 { ~left(track: track, frame: frame, index: index) }

    private func interleavedFrame(track: Int, frame: Int) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(frameBytes)
        for i in 0..<4704 {
            out.append(left(track: track, frame: frame, index: i))
            out.append(right(track: track, frame: frame, index: i))
        }
        return out
    }

    /// One audio sector: `audio` (a slice of a frame), optionally starting a frame,
    /// topped up with a padding packet when it doesn't fill the sector.
    private func audioSector(_ audio: [UInt8], startsFrame: Bool) -> [UInt8] {
        let frameInfos = startsFrame ? 1 : 0
        let capacityOne = sectorSize - 1 - 2 - 3 * frameInfos
        let capacityTwo = sectorSize - 1 - 4 - 3 * frameInfos
        var sector = blank()
        func packetInfo(frameStart: Bool, type: Int, length: Int) -> [UInt8] {
            [UInt8((frameStart ? 0x80 : 0) | (type << 3) | ((length >> 8) & 7)), UInt8(length & 0xFF)]
        }
        precondition(audio.count <= capacityOne)
        if audio.count <= capacityTwo && audio.count < capacityOne {
            sector[0] = UInt8(2 << 5 | frameInfos << 2)               // 2 packets, not DST
            let padding = capacityTwo - audio.count
            put(&sector, 1, packetInfo(frameStart: startsFrame, type: 2, length: audio.count))
            put(&sector, 3, packetInfo(frameStart: false, type: 7, length: padding))
            let body = 5 + 3 * frameInfos
            put(&sector, body, audio)                                  // frame info bytes stay zero
        } else {
            sector[0] = UInt8(1 << 5 | frameInfos << 2)
            put(&sector, 1, packetInfo(frameStart: startsFrame, type: 2, length: audio.count))
            put(&sector, 3 + 3 * frameInfos, audio)
        }
        return sector
    }

    private func sectors(forFrame frame: [UInt8]) -> [[UInt8]] {
        var result = [[UInt8]]()
        var offset = 0
        var first = true
        while offset < frame.count {
            let capacity = sectorSize - 1 - 2 - (first ? 3 : 0)
            let take = min(capacity, frame.count - offset)
            result.append(audioSector(Array(frame[offset..<(offset + take)]), startsFrame: first))
            offset += take
            first = false
        }
        return result
    }

    private let masterLSN = 510
    private let areaLSN = 540
    private let audioLSN = 600

    /// A two-track stereo image; track 1 has 4 frames, track 2 has 3.
    private func makeImage(trackFrames: [Int] = [4, 3], spillText: Bool = false) -> [UInt8] {
        var image = [UInt8](repeating: 0, count: (audioLSN + 200) * sectorSize)
        func write(_ sector: [UInt8], at lsn: Int) {
            image.replaceSubrange((lsn * sectorSize)..<((lsn + 1) * sectorSize), with: sector)
        }

        var master = blank()
        put(&master, 0, ascii("SACDMTOC"))
        put(&master, 8, [1, 20])
        put(&master, 64, be32(areaLSN))                               // area_1_toc_1_start
        put(&master, 84, be16(spillText ? 5 : 4))                     // area_1_toc_size
        put(&master, 136, ascii("en") + [2, 0])                        // locale 0: ISO 8859-1
        write(master, at: masterLSN)

        var text = blank()
        put(&text, 0, ascii("SACDText"))
        put(&text, 16, be16(64))                                      // album title
        put(&text, 18, be16(100))                                     // album artist
        put(&text, 64, ascii("Test Album") + [0])
        put(&text, 100, ascii("Test Artist") + [0])
        write(text, at: masterLSN + 1)

        var starts = [Int](), lengths = [Int]()
        var lsn = audioLSN
        var audio = [(lsn: Int, sectors: [[UInt8]])]()
        for (t, frames) in trackFrames.enumerated() {
            var trackSectors = [[UInt8]]()
            for f in 0..<frames { trackSectors += sectors(forFrame: interleavedFrame(track: t + 1, frame: f)) }
            audio.append((lsn, trackSectors))
            starts.append(lsn)
            lengths.append(trackSectors.count)
            lsn += trackSectors.count
        }
        for track in audio {
            for (i, s) in track.sectors.enumerated() { write(s, at: track.lsn + i) }
        }

        var area = blank()
        put(&area, 0, ascii("TWOCHTOC"))
        put(&area, 8, [1, 20])
        put(&area, 10, be16(spillText ? 5 : 4))                       // TOC size in sectors
        area[21] = 2                                                  // frame format: DSD 3 in 14
        area[32] = 2                                                  // channels
        area[69] = UInt8(trackFrames.count)                           // track count
        put(&area, 88, ascii("en") + [2, 0])                           // language 0: ISO 8859-1
        write(area, at: areaLSN)

        var list = blank()
        put(&list, 0, ascii("SACDTRL1"))
        for t in 0..<trackFrames.count {
            put(&list, 8 + 4 * t, be32(starts[t]))
            put(&list, 8 + 4 * 255 + 4 * t, be32(lengths[t]))
        }
        write(list, at: areaLSN + 1)

        var times = blank()
        put(&times, 0, ascii("SACDTRL2"))
        for (t, frames) in trackFrames.enumerated() {
            put(&times, 8 + 4 * 255 + 4 * t, [0, UInt8(frames / 75), UInt8(frames % 75), 0])
        }
        write(times, at: areaLSN + 2)

        var titles = blank()
        put(&titles, 0, ascii("SACDTTxt"))
        let first: [UInt8] = [2, 0, 0, 0, 0x01, 0x20] + ascii("First Track") + [0, 0x02, 0x20] + ascii("Performer One") + [0]
        let second: [UInt8] = [1, 0, 0, 0, 0x01, 0x20] + ascii("Second Track") + [0]
        if spillText {
            // Real discs keep the strings in the sector(s) after the "SACDTTxt" header
            // sector: positions ≥ 2048 are offsets from the start of that header sector.
            put(&titles, 8, be16(2048 + 40))
            put(&titles, 10, be16(2048 + 120))
            var more = blank()
            put(&more, 40, first)
            put(&more, 120, second)
            write(more, at: areaLSN + 4)
        } else {
            put(&titles, 8, be16(40))
            put(&titles, 10, be16(120))
            put(&titles, 40, first)
            put(&titles, 120, second)
        }
        write(titles, at: areaLSN + 3)

        return image
    }

    private func writeImage(_ bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fwtest-\(UUID().uuidString).iso")
        try Data(bytes).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    // MARK: - Tests

    func testDiscStructureIsParsed() throws {
        let url = try writeImage(makeImage())
        let disc = try SACDISO.open(try SACDFileSectorSource(url: url))
        XCTAssertEqual(disc.albumTitle, "Test Album")
        XCTAssertEqual(disc.albumArtist, "Test Artist")
        XCTAssertNil(disc.multichannel)
        let area = try XCTUnwrap(disc.stereo)
        XCTAssertEqual(area.channels, 2)
        XCTAssertEqual(area.frameFormat, 2)
        XCTAssertFalse(area.isDST)
        XCTAssertEqual(area.tracks.count, 2)
        XCTAssertEqual(area.tracks[0].number, 1)
        XCTAssertEqual(area.tracks[0].startLSN, audioLSN)
        XCTAssertEqual(area.tracks[0].lengthLSN, 4 * 5)               // 5 sectors per frame
        XCTAssertEqual(area.tracks[1].startLSN, audioLSN + 20)
        XCTAssertEqual(area.tracks[0].title, "First Track")
        XCTAssertEqual(area.tracks[0].performer, "Performer One")
        XCTAssertEqual(area.tracks[1].title, "Second Track")
        XCTAssertEqual(area.tracks[0].durationSeconds, 4.0 / 75.0, accuracy: 1e-9)
    }

    func testTitlesStoredInFollowingSectorsAreRead() throws {
        let url = try writeImage(makeImage(spillText: true))
        let area = try XCTUnwrap(try SACDISO.open(try SACDFileSectorSource(url: url)).stereo)
        XCTAssertEqual(area.tracks.count, 2)
        XCTAssertEqual(area.tracks[0].title, "First Track")
        XCTAssertEqual(area.tracks[0].performer, "Performer One")
        XCTAssertEqual(area.tracks[1].title, "Second Track")
        XCTAssertEqual(area.tracks[1].startLSN, audioLSN + 20)         // the lists after the text were still found
    }

    func testTrackFramesAreReassembledAndSplitIntoChannels() throws {
        let url = try writeImage(makeImage())
        let reader = try SACDTrackReader(source: try SACDFileSectorSource(url: url), trackNumber: 2)
        var leftBytes = [UInt8](), rightBytes = [UInt8]()
        while let chunk = try reader.next() {
            XCTAssertEqual(chunk.left.count, chunk.right.count)
            leftBytes += chunk.left
            rightBytes += chunk.right
        }
        XCTAssertEqual(leftBytes.count, 3 * 4704)                      // track 2 has 3 frames
        XCTAssertEqual(rightBytes.count, 3 * 4704)
        for f in 0..<3 {
            for i in [0, 1, 2000, 4703] {
                XCTAssertEqual(leftBytes[f * 4704 + i], left(track: 2, frame: f, index: i), "L f\(f) i\(i)")
                XCTAssertEqual(rightBytes[f * 4704 + i], right(track: 2, frame: f, index: i), "R f\(f) i\(i)")
            }
        }
    }

    func testISOTrackConvertsToDoP() throws {
        let url = try writeImage(makeImage())
        let result = try DSDDoPDecoder.convert(sourceURL: SACDISOTrackURL.make(url, track: 1), mode: .dop)
        defer { try? FileManager.default.removeItem(at: result.url) }
        XCTAssertTrue(result.isDoP)
        XCTAssertEqual(result.label, "DSD64")

        let wav = [UInt8](try Data(contentsOf: result.url))
        let silence = Int((176_400 * DSDDoPDecoder.silenceSeconds).rounded())
        let musicFrames = 4 * 4704 / 2                                 // 4 DSD frames, 2 bytes per sample
        XCTAssertEqual((wav.count - 44) / 6, silence * 2 + musicFrames)

        // First music sample: DSD bytes 0 and 1 of frame 0, each channel.
        let o = 44 + silence * 6
        XCTAssertEqual(wav[o], left(track: 1, frame: 0, index: 1))
        XCTAssertEqual(wav[o + 1], left(track: 1, frame: 0, index: 0))
        XCTAssertEqual(wav[o + 3], right(track: 1, frame: 0, index: 1))
        XCTAssertEqual(wav[o + 4], right(track: 1, frame: 0, index: 0))
        XCTAssertEqual(wav[o + 2], silence % 2 == 0 ? 0x05 : 0xFA)
    }

    func testTrackNumberSelectsTheTrack() throws {
        let url = try writeImage(makeImage())
        XCTAssertEqual(SACDISOTrackURL.trackNumber(in: SACDISOTrackURL.make(url, track: 7)), 7)
        XCTAssertEqual(SACDISOTrackURL.trackNumber(in: url), 1)

        let a = try DSDDoPDecoder.convert(sourceURL: SACDISOTrackURL.make(url, track: 1), mode: .pcm)
        let b = try DSDDoPDecoder.convert(sourceURL: SACDISOTrackURL.make(url, track: 2), mode: .pcm)
        defer {
            try? FileManager.default.removeItem(at: a.url)
            try? FileManager.default.removeItem(at: b.url)
        }
        let sizeA = try FileManager.default.attributesOfItem(atPath: a.url.path)[.size] as? Int ?? 0
        let sizeB = try FileManager.default.attributesOfItem(atPath: b.url.path)[.size] as? Int ?? 0
        XCTAssertGreaterThan(sizeA, sizeB)                             // 4 frames vs 3 frames
    }

    func testMissingTrackIsReported() throws {
        let url = try writeImage(makeImage())
        XCTAssertThrowsError(try DSDDoPDecoder.convert(sourceURL: SACDISOTrackURL.make(url, track: 9), mode: .dop)) {
            guard case SACDError.noSuchTrack(9) = $0 else { return XCTFail("wrong error: \($0)") }
        }
    }

    func testNonSACDImageIsRejected() throws {
        let url = try writeImage([UInt8](repeating: 0x42, count: 520 * sectorSize))
        XCTAssertThrowsError(try SACDISO.open(try SACDFileSectorSource(url: url))) {
            guard case SACDError.notAnSACD = $0 else { return XCTFail("wrong error: \($0)") }
        }
    }

    func testVirtualPaths() {
        XCTAssertEqual(SACDVirtualPath.trackName(number: 3, title: "A/B: C"), "03 A-B- C.sacdtrack")
        XCTAssertEqual(SACDVirtualPath.trackName(number: 12, title: nil), "Track 12.sacdtrack")
        XCTAssertEqual(SACDVirtualPath.trackName(number: 5, title: "  "), "Track 05.sacdtrack")
        XCTAssertTrue(SACDVirtualPath.isImage("dir/Disc.ISO"))
        XCTAssertFalse(SACDVirtualPath.isImage("dir/track.flac"))

        let split = SACDVirtualPath.split("Jazz/Pure 2.iso/03 Title.sacdtrack")
        XCTAssertEqual(split?.image, "Jazz/Pure 2.iso")
        XCTAssertEqual(split?.track, 3)
        XCTAssertNil(SACDVirtualPath.split("Jazz/song.flac"))
        XCTAssertNil(SACDVirtualPath.split("Jazz/folder/03 Title.sacdtrack"))     // not inside an image
        XCTAssertNil(SACDVirtualPath.split("Jazz/Pure 2.iso/Title.sacdtrack"))    // no track number
        XCTAssertEqual(SACDVirtualPath.split("Jazz/Pure 2.iso/Track 12.sacdtrack")?.track, 12)
        XCTAssertEqual(SACDVirtualPath.split("Jazz/Pure 2.iso/03 Song 7.sacdtrack")?.track, 3)
    }

    func testTOCPrefetchOpensAnImageWithoutReadingAudio() async throws {
        let image = makeImage()
        var reads = [(lsn: Int, count: Int)]()
        let toc = try await SACDTOCPrefetch.load { lsn, count in
            reads.append((lsn, count))
            return Array(image[(lsn * 2048)..<((lsn + count) * 2048)])
        }
        let disc = try SACDISO.open(toc)
        XCTAssertEqual(disc.stereo?.tracks.count, 2)
        XCTAssertEqual(disc.stereo?.tracks.first?.title, "First Track")
        XCTAssertTrue(reads.contains { $0.lsn == 510 })
        XCTAssertTrue(reads.contains { $0.lsn == 540 })
        XCTAssertTrue(reads.allSatisfy { $0.lsn < 600 }, "the audio area must not be read")
    }

    func testSACDTrackReaderWorksOverAByteStream() throws {
        let source = SACDByteSectorSource(source: MemoryByteSource(bytes: makeImage()))
        let reader = try SACDTrackReader(source: source, trackNumber: 1)
        var total = 0
        while let chunk = try reader.next() { total += chunk.left.count }
        XCTAssertEqual(total, 4 * 4704)
    }

    func testMemorySourceOnlyServesWhatItHolds() throws {
        let memory = SACDMemorySectorSource()
        memory.add(lsn: 10, bytes: [UInt8](repeating: 7, count: 2 * 2048))
        XCTAssertEqual(try memory.readSectors(11, count: 1).count, 2048)
        XCTAssertThrowsError(try memory.readSectors(12, count: 1))
        XCTAssertThrowsError(try memory.readSectors(9, count: 1))
    }

    func testDSTDecoderCanBeCreated() {
        #if canImport(CDST)
        let decoder = fwdst_create(2)
        XCTAssertNotNil(decoder)
        fwdst_destroy(decoder)
        #endif
    }
}
