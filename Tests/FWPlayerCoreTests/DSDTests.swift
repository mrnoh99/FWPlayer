import XCTest
@testable import FWPlayerCore

/// Tests for DSF/DFF parsing, DoP packing, DSD → PCM conversion and ID3 tags,
/// using small synthetic files built in memory.
final class DSDTests: XCTestCase {

    // MARK: - Byte helpers

    private func le32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }
    private func le64(_ v: UInt64) -> [UInt8] { le32(UInt32(v & 0xFFFF_FFFF)) + le32(UInt32(v >> 32)) }
    private func be16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xFF)] }
    private func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
    private func be64(_ v: UInt64) -> [UInt8] { be32(UInt32(v >> 32)) + be32(UInt32(v & 0xFFFF_FFFF)) }
    private func ascii(_ s: String) -> [UInt8] { Array(s.utf8) }
    private func cat(_ parts: [UInt8]...) -> [UInt8] { parts.flatMap { $0 } }

    private func write(_ bytes: [UInt8], ext: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fwtest-\(UUID().uuidString).\(ext)")
        try Data(bytes).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    // MARK: - File builders

    /// A stereo (or mono when `right` is nil) DSF. Channel data length must be a
    /// multiple of `blockSize`.
    private func makeDSF(left: [UInt8], right: [UInt8]?, rate: UInt32 = 2_822_400,
                         bitsPerSample: UInt32 = 8, blockSize: Int = 8,
                         id3: [UInt8] = []) -> [UInt8] {
        let channels: UInt32 = right == nil ? 1 : 2
        var data = [UInt8]()
        for g in 0..<(left.count / blockSize) {
            data += left[(g * blockSize)..<((g + 1) * blockSize)]
            if let right { data += right[(g * blockSize)..<((g + 1) * blockSize)] }
        }
        let dsdChunkSize = 28
        let fmtChunkSize = 52
        let dataChunkSize = 12 + data.count
        let audioEnd = dsdChunkSize + fmtChunkSize + dataChunkSize
        let metadataPointer: UInt64 = id3.isEmpty ? 0 : UInt64(audioEnd)
        let channelType: UInt32 = channels == 1 ? 1 : 2
        return cat(
            ascii("DSD "), le64(28), le64(UInt64(audioEnd + id3.count)), le64(metadataPointer),
            ascii("fmt "), le64(UInt64(fmtChunkSize)),
            le32(1), le32(0), le32(channelType), le32(channels), le32(rate),
            le32(bitsPerSample), le64(UInt64(left.count * 8)), le32(UInt32(blockSize)), le32(0),
            ascii("data"), le64(UInt64(dataChunkSize)), data,
            id3
        )
    }

    /// A DSDIFF file with byte-interleaved stereo data.
    private func makeDFF(left: [UInt8], right: [UInt8], rate: UInt32 = 2_822_400,
                         compression: String = "DSD ") -> [UInt8] {
        var interleaved = [UInt8]()
        for i in 0..<left.count { interleaved += [left[i], right[i]] }

        let name = ascii("not compressed")
        var cmpr = cat(ascii(compression), [UInt8(name.count)], name)
        let cmprSize = cmpr.count
        if cmpr.count % 2 == 1 { cmpr.append(0) }

        let sub = cat(
            ascii("FS  "), be64(4), be32(rate),
            ascii("CHNL"), be64(10), be16(2), ascii("SLFT"), ascii("SRGT"),
            ascii("CMPR"), be64(UInt64(cmprSize)), cmpr
        )
        let prop = cat(ascii("SND "), sub)
        let fver: [UInt8] = [1, 5, 0, 0]
        let body = cat(
            ascii("DSD "),
            ascii("FVER"), be64(4), fver,
            ascii("PROP"), be64(UInt64(prop.count)), prop,
            ascii("DSD "), be64(UInt64(interleaved.count)), interleaved
        )
        return cat(ascii("FRM8"), be64(UInt64(body.count)), body)
    }

    // MARK: - WAV reading

    private struct WAV {
        let channels: Int
        let rate: Int
        let bits: Int
        let data: [UInt8]
    }

    private func readWAV(_ url: URL) throws -> WAV {
        let d = [UInt8](try Data(contentsOf: url))
        XCTAssertGreaterThanOrEqual(d.count, 44)
        XCTAssertEqual(String(decoding: d[0..<4], as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: d[8..<12], as: UTF8.self), "WAVE")
        func u16(_ o: Int) -> Int { Int(d[o]) | Int(d[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
        XCTAssertEqual(u32(40), d.count - 44, "data chunk size must match the file")
        XCTAssertEqual(u32(4), d.count - 8, "RIFF size must match the file")
        return WAV(channels: u16(22), rate: u32(24), bits: u16(34), data: Array(d[44...]))
    }

    // MARK: - DoP

    func testDoPPacksMarkersAndBytes() throws {
        let left: [UInt8] = (0..<16).map { UInt8(0x10 + $0) }
        let right: [UInt8] = (0..<16).map { UInt8(0xA0 + $0) }
        let url = try write(makeDSF(left: left, right: right), ext: "dsf")

        let result = try DSDDoPDecoder.convert(sourceURL: url, mode: .dop)
        defer { try? FileManager.default.removeItem(at: result.url) }
        XCTAssertTrue(result.isDoP)
        XCTAssertEqual(result.label, "DSD64")

        let wav = try readWAV(result.url)
        XCTAssertEqual(wav.channels, 2)
        XCTAssertEqual(wav.bits, 24)
        XCTAssertEqual(wav.rate, 176_400)

        let silence = Int((176_400 * DSDDoPDecoder.silenceSeconds).rounded())
        XCTAssertEqual(wav.data.count, (silence * 2 + 8) * 6)

        func frame(_ f: Int) -> [UInt8] { Array(wav.data[(f * 6)..<(f * 6 + 6)]) }
        // Markers alternate 0x05 / 0xFA on every frame, across silence and music.
        for f in [0, 1, 2, silence - 1, silence, silence + 1, silence + 7, silence * 2 + 7] {
            let marker: UInt8 = f % 2 == 0 ? 0x05 : 0xFA
            XCTAssertEqual(frame(f)[2], marker, "left marker, frame \(f)")
            XCTAssertEqual(frame(f)[5], marker, "right marker, frame \(f)")
        }
        // DSD silence before the music.
        XCTAssertEqual(Array(frame(0)[0..<2]), [0x69, 0x69])
        // Music: 16 DSD bits per sample, oldest byte in the middle, newest in the low byte.
        for j in 0..<8 {
            let f = frame(silence + j)
            XCTAssertEqual(f[0], left[2 * j + 1])
            XCTAssertEqual(f[1], left[2 * j])
            XCTAssertEqual(f[3], right[2 * j + 1])
            XCTAssertEqual(f[4], right[2 * j])
        }
    }

    func testLSBFirstDSFIsBitReversed() throws {
        let left = [UInt8](repeating: 0x01, count: 8)
        let right = [UInt8](repeating: 0x80, count: 8)
        let url = try write(makeDSF(left: left, right: right, bitsPerSample: 1), ext: "dsf")
        let result = try DSDDoPDecoder.convert(sourceURL: url, mode: .dop)
        defer { try? FileManager.default.removeItem(at: result.url) }
        let wav = try readWAV(result.url)
        let silence = Int((176_400 * DSDDoPDecoder.silenceSeconds).rounded())
        let f = Array(wav.data[(silence * 6)..<(silence * 6 + 6)])
        XCTAssertEqual(f[0], 0x80)      // 0x01 reversed
        XCTAssertEqual(f[1], 0x80)
        XCTAssertEqual(f[3], 0x01)      // 0x80 reversed
        XCTAssertEqual(f[4], 0x01)
    }

    func testDFFDeinterleavesAndPacks() throws {
        let left: [UInt8] = (0..<8).map { UInt8(0x20 + $0) }
        let right: [UInt8] = (0..<8).map { UInt8(0xC0 + $0) }
        let url = try write(makeDFF(left: left, right: right), ext: "dff")
        let result = try DSDDoPDecoder.convert(sourceURL: url, mode: .dop)
        defer { try? FileManager.default.removeItem(at: result.url) }
        XCTAssertTrue(result.isDoP)
        let wav = try readWAV(result.url)
        let silence = Int((176_400 * DSDDoPDecoder.silenceSeconds).rounded())
        for j in 0..<4 {
            let f = Array(wav.data[((silence + j) * 6)..<((silence + j) * 6 + 6)])
            XCTAssertEqual(f[0], left[2 * j + 1])
            XCTAssertEqual(f[1], left[2 * j])
            XCTAssertEqual(f[3], right[2 * j + 1])
            XCTAssertEqual(f[4], right[2 * j])
        }
    }

    func testDSD128UsesTheDoubleRateCarrier() throws {
        let bytes = [UInt8](repeating: 0x69, count: 8)
        let url = try write(makeDSF(left: bytes, right: bytes, rate: 5_644_800), ext: "dsf")
        let result = try DSDDoPDecoder.convert(sourceURL: url, mode: .dop)
        defer { try? FileManager.default.removeItem(at: result.url) }
        XCTAssertTrue(result.isDoP)
        XCTAssertEqual(result.label, "DSD128")
        XCTAssertEqual(try readWAV(result.url).rate, 352_800)
    }

    // MARK: - Unsupported input

    func testDSD256FallsBackToPCM() throws {
        let bytes = [UInt8](repeating: 0x69, count: 8)
        let url = try write(makeDSF(left: bytes, right: bytes, rate: 11_289_600), ext: "dsf")
        let result = try DSDDoPDecoder.convert(sourceURL: url, mode: .dop)
        defer { try? FileManager.default.removeItem(at: result.url) }
        XCTAssertFalse(result.isDoP)
        XCTAssertEqual(result.label, "DSD256")
        XCTAssertEqual(try readWAV(result.url).rate, 176_400)
    }

    func testDSD512And1024ConvertToPCM() throws {
        let bytes = [UInt8](repeating: 0x69, count: 8)
        for (rate, label) in [(22_579_200, "DSD512"), (45_158_400, "DSD1024"), (24_576_000, "DSD512 (48 kHz)")] {
            let url = try write(makeDSF(left: bytes, right: bytes, rate: UInt32(rate)), ext: "dsf")
            let result = try DSDDoPDecoder.convert(sourceURL: url, mode: .dop)
            defer { try? FileManager.default.removeItem(at: result.url) }
            XCTAssertFalse(result.isDoP, label)
            XCTAssertEqual(result.label, label)
            XCTAssertEqual(try readWAV(result.url).rate, rate % 3_072_000 == 0 ? 192_000 : 176_400, label)
        }
    }

    func testMonoIsRejected() throws {
        let url = try write(makeDSF(left: [UInt8](repeating: 0x69, count: 8), right: nil), ext: "dsf")
        XCTAssertThrowsError(try DSDDoPDecoder.convert(sourceURL: url, mode: .dop)) { error in
            guard case AudioDecoderError.dsdUnsupported = error else { return XCTFail("wrong error: \(error)") }
        }
    }

    func testDSTCompressionIsRejected() throws {
        let bytes = [UInt8](repeating: 0x69, count: 8)
        let url = try write(makeDFF(left: bytes, right: bytes, compression: "DST "), ext: "dff")
        XCTAssertThrowsError(try DSDDoPDecoder.convert(sourceURL: url, mode: .dop)) { error in
            guard case AudioDecoderError.dsdUnsupported = error else { return XCTFail("wrong error: \(error)") }
        }
    }

    func testGarbageFileIsRejected() throws {
        let url = try write([UInt8](repeating: 0x42, count: 64), ext: "dsf")
        XCTAssertThrowsError(try DSDDoPDecoder.convert(sourceURL: url, mode: .dop))
    }

    // MARK: - DSD → PCM

    /// First-order delta-sigma modulation of a sine into MSB-first DSD bytes.
    private func modulate(frequency: Double, amplitude: Double, seconds: Double, rate: Double = 2_822_400) -> [UInt8] {
        let samples = Int(rate * seconds) / 8 * 8
        var bytes = [UInt8](repeating: 0, count: samples / 8)
        var integrator = 0.0, previous = 0.0
        for n in 0..<samples {
            let x = amplitude * sin(2 * Double.pi * frequency * Double(n) / rate)
            integrator += x - previous
            let bit = integrator >= 0
            previous = bit ? 1 : -1
            if bit { bytes[n / 8] |= 0x80 >> UInt8(n % 8) }
        }
        return bytes
    }

    func testPCMConversionKeepsLevelAndFrequency() throws {
        var tone = modulate(frequency: 1000, amplitude: 0.25, seconds: 0.2)
        while tone.count % 8 != 0 { tone.append(0x69) }        // whole DSF blocks
        let url = try write(makeDSF(left: tone, right: tone), ext: "dsf")
        let result = try DSDDoPDecoder.convert(sourceURL: url, mode: .pcm)
        defer { try? FileManager.default.removeItem(at: result.url) }
        XCTAssertFalse(result.isDoP)

        let wav = try readWAV(result.url)
        XCTAssertEqual(wav.rate, 176_400)
        XCTAssertEqual(wav.bits, 24)

        // Decode the left channel (24-bit LE) and skip the filter start-up.
        let frames = wav.data.count / 6
        XCTAssertGreaterThan(frames, 30_000)
        var samples = [Double]()
        samples.reserveCapacity(frames)
        for f in 0..<frames {
            let b0 = Int(wav.data[f * 6]), b1 = Int(wav.data[f * 6 + 1]), b2 = Int(wav.data[f * 6 + 2])
            var v = b0 | b1 << 8 | b2 << 16
            if v & 0x80_0000 != 0 { v -= 1 << 24 }
            samples.append(Double(v) / 8_388_607)
        }
        let steady = samples[2000..<(frames - 2000)]
        let rms = (steady.reduce(0) { $0 + $1 * $1 } / Double(steady.count)).squareRoot()
        // Input amplitude 0.25 → ×2 (SACD 0 dB = full scale) = 0.5 peak → 0.3536 RMS.
        XCTAssertEqual(rms, 0.5 / 2.0.squareRoot(), accuracy: 0.02)

        // The 1 kHz component (correlation over 100 whole cycles = 17,640 frames)
        // carries the expected amplitude: the tone survived at the right frequency.
        let window = Array(samples[2000..<(2000 + 17_640)])
        var inPhase = 0.0, quadrature = 0.0
        for (n, value) in window.enumerated() {
            let angle = 2 * Double.pi * 1000 * Double(n) / 176_400
            inPhase += value * sin(angle)
            quadrature += value * cos(angle)
        }
        let amplitude = 2 * (inPhase * inPhase + quadrature * quadrature).squareRoot() / Double(window.count)
        XCTAssertEqual(amplitude, 0.5, accuracy: 0.02)
    }

    func testDSD512ToneKeepsItsLevel() throws {
        // 22.5792 MHz: the same 1 kHz tone through the m = 8 filter.
        let tone = modulate(frequency: 1000, amplitude: 0.25, seconds: 0.05, rate: 22_579_200)
        let usable = tone.count / 8 * 8
        let url = try write(makeDSF(left: Array(tone[0..<usable]), right: Array(tone[0..<usable]), rate: 22_579_200), ext: "dsf")
        let result = try DSDDoPDecoder.convert(sourceURL: url, mode: .pcm)
        defer { try? FileManager.default.removeItem(at: result.url) }
        let wav = try readWAV(result.url)
        XCTAssertEqual(wav.rate, 176_400)
        let frames = wav.data.count / 6
        XCTAssertGreaterThan(frames, 6_000)
        var samples = [Double]()
        for f in 0..<frames {
            var v = Int(wav.data[f * 6]) | Int(wav.data[f * 6 + 1]) << 8 | Int(wav.data[f * 6 + 2]) << 16
            if v & 0x80_0000 != 0 { v -= 1 << 24 }
            samples.append(Double(v) / 8_388_607)
        }
        let steady = samples[1000..<(frames - 500)]
        let rms = (steady.reduce(0) { $0 + $1 * $1 } / Double(steady.count)).squareRoot()
        XCTAssertEqual(rms, 0.5 / 2.0.squareRoot(), accuracy: 0.03)
    }

    func testPCMConversionOfSilenceIsSilent() throws {
        let silence = [UInt8](repeating: 0x69, count: 4096)
        let url = try write(makeDSF(left: silence, right: silence, blockSize: 4096), ext: "dsf")
        let result = try DSDDoPDecoder.convert(sourceURL: url, mode: .pcm)
        defer { try? FileManager.default.removeItem(at: result.url) }
        let wav = try readWAV(result.url)
        XCTAssertGreaterThan(wav.data.count, 6 * 100)
        for f in 50..<(wav.data.count / 6) {
            var v = Int(wav.data[f * 6]) | Int(wav.data[f * 6 + 1]) << 8 | Int(wav.data[f * 6 + 2]) << 16
            if v & 0x80_0000 != 0 { v -= 1 << 24 }
            XCTAssertLessThan(abs(v), 8_000, "frame \(f)")
        }
    }

    // MARK: - Tags

    private func id3Frame(_ id: String, _ text: String) -> [UInt8] {
        let body = cat([3], ascii(text))                          // encoding 3 = UTF-8
        return cat(ascii(id), be32(UInt32(body.count)), [0, 0], body)
    }

    private func syncsafe(_ v: Int) -> [UInt8] {
        [UInt8((v >> 21) & 0x7F), UInt8((v >> 14) & 0x7F), UInt8((v >> 7) & 0x7F), UInt8(v & 0x7F)]
    }

    func testDSFTagsAreRead() throws {
        let frames = cat(
            id3Frame("TIT2", "Hotel California"), id3Frame("TPE1", "Eagles"),
            id3Frame("TALB", "Hotel California"), id3Frame("TDRC", "1976"), id3Frame("TCON", "Rock")
        )
        let tag = cat(ascii("ID3"), [3, 0, 0], syncsafe(frames.count), frames)
        let bytes = [UInt8](repeating: 0x69, count: 8)
        let url = try write(makeDSF(left: bytes, right: bytes, id3: tag), ext: "dsf")

        let tags = DSDTags.read(from: url)
        XCTAssertEqual(tags["TITLE"], "Hotel California")
        XCTAssertEqual(tags["ARTIST"], "Eagles")
        XCTAssertEqual(tags["ALBUM"], "Hotel California")
        XCTAssertEqual(tags["DATE"], "1976")
        XCTAssertEqual(tags["GENRE"], "Rock")
    }

    func testTagsOfUntaggedOrNonDSDFilesAreEmpty() throws {
        let bytes = [UInt8](repeating: 0x69, count: 8)
        let dsf = try write(makeDSF(left: bytes, right: bytes), ext: "dsf")
        XCTAssertTrue(DSDTags.read(from: dsf).isEmpty)
        let flac = try write([UInt8](repeating: 0, count: 64), ext: "flac")
        XCTAssertTrue(DSDTags.read(from: flac).isEmpty)
    }
}
