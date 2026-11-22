import XCTest
@testable import FWPlayerCore

final class PCMFileTests: XCTestCase {

    // MARK: - Builders

    private func le32(_ v: Int) -> [UInt8] { [UInt8(v & 255), UInt8((v >> 8) & 255), UInt8((v >> 16) & 255), UInt8((v >> 24) & 255)] }
    private func le16(_ v: Int) -> [UInt8] { [UInt8(v & 255), UInt8((v >> 8) & 255)] }
    private func be32(_ v: Int) -> [UInt8] { le32(v).reversed() }
    private func be16(_ v: Int) -> [UInt8] { le16(v).reversed() }

    /// Sample values as `bits`-bit signed integers for `frames` frames of `channels`.
    private func values(frames: Int, channels: Int, bits: Int) -> [Int] {
        let limit = (1 << (bits - 1)) - 1
        return (0..<(frames * channels)).map { i in
            let v = (i * 7919 + 13) % (2 * limit + 1) - limit
            return v
        }
    }

    private func bytes(_ v: Int, bits: Int, bigEndian: Bool) -> [UInt8] {
        let n = bits / 8
        let u = UInt64(bitPattern: Int64(v))
        let le = (0..<n).map { UInt8((u >> UInt64(8 * $0)) & 255) }
        return bigEndian ? le.reversed() : le
    }

    private func makeWAV(rate: Int, channels: Int, bits: Int, samples: [Int], list: [UInt8] = [], extensible: Bool = false) -> Data {
        var data = [UInt8]()
        samples.forEach { data += bytes($0, bits: bits, bigEndian: false) }
        var fmt = le16(extensible ? 0xFFFE : 1) + le16(channels) + le32(rate)
        fmt += le32(rate * channels * bits / 8) + le16(channels * bits / 8) + le16(bits)
        if extensible { fmt += le16(22) + le16(bits) + le32(3) + le16(1) + [UInt8](repeating: 0, count: 14) }
        var body = Array("WAVE".utf8)
        body += Array("fmt ".utf8) + le32(fmt.count) + fmt
        body += Array("data".utf8) + le32(data.count) + data + (data.count % 2 == 1 ? [0] : [])
        body += list
        return Data(Array("RIFF".utf8) + le32(body.count) + body)
    }

    private func extended(_ rate: Int) -> [UInt8] {
        var exp = 16383 + 63
        var mant = UInt64(rate)
        while mant & (1 << 63) == 0 { mant <<= 1; exp -= 1 }
        return be16(exp) + (0..<8).map { UInt8((mant >> UInt64(56 - 8 * $0)) & 255) }
    }

    private func makeAIFF(rate: Int, channels: Int, bits: Int, samples: [Int]) -> Data {
        var data = [UInt8]()
        samples.forEach { data += bytes($0, bits: bits, bigEndian: true) }
        let frames = samples.count / channels
        let comm = be16(channels) + be32(frames) + be16(bits) + extended(rate)
        var body = Array("AIFF".utf8)
        body += Array("COMM".utf8) + be32(comm.count) + comm
        body += Array("SSND".utf8) + be32(8 + data.count) + be32(0) + be32(0) + data
        return Data(Array("FORM".utf8) + be32(body.count) + body)
    }

    private func decodeAll(_ d: PCMFileDecoder) throws -> [Float] {
        var all = [Float]()
        while let s = try d.nextSamples() { all += s }
        return all
    }

    private func check(_ d: PCMFileDecoder, channels: Int, bits: Int, samples: [Int], file: StaticString = #filePath, line: UInt = #line) throws {
        let got = try decodeAll(d)
        let frames = samples.count / channels
        XCTAssertEqual(got.count, frames * 2, file: file, line: line)
        let scale = Float(Int64(1) << Int64(bits - 1))
        for f in 0..<frames {
            let l = Float(samples[f * channels]) / scale
            let r = Float(samples[f * channels + channels - 1]) / scale
            XCTAssertEqual(got[2 * f], l, "L \(f)", file: file, line: line)
            XCTAssertEqual(got[2 * f + 1], r, "R \(f)", file: file, line: line)
            if got[2 * f] != l || got[2 * f + 1] != r { return }
        }
    }

    // MARK: - WAV

    func testWAVStereo16_24_32() throws {
        for bits in [16, 24, 32] {
            let samples = values(frames: 20000, channels: 2, bits: bits)
            let d = try PCMFileDecoder(source: MemoryByteSource(data: makeWAV(rate: 96000, channels: 2, bits: bits, samples: samples)))
            XCTAssertEqual(d.sampleRate, 96000)
            XCTAssertEqual(d.durationSeconds, 20000.0 / 96000.0, accuracy: 1e-9)
            try check(d, channels: 2, bits: bits, samples: samples)
        }
    }

    func testWAVMonoIsDuplicated() throws {
        let samples = values(frames: 5000, channels: 1, bits: 16)
        let d = try PCMFileDecoder(source: MemoryByteSource(data: makeWAV(rate: 44100, channels: 1, bits: 16, samples: samples)))
        try check(d, channels: 1, bits: 16, samples: samples)
    }

    func testWAVExtensibleHeader() throws {
        let samples = values(frames: 3000, channels: 2, bits: 24)
        let d = try PCMFileDecoder(source: MemoryByteSource(data: makeWAV(rate: 192000, channels: 2, bits: 24, samples: samples, extensible: true)))
        try check(d, channels: 2, bits: 24, samples: samples)
    }

    func testWAVInfoTagsAfterData() throws {
        var info = Array("INFO".utf8)
        for (id, text) in [("IART", "Glenn Gould"), ("IPRD", "Goldberg Variations"), ("IGNR", "Classical")] {
            let t = Array(text.utf8) + [0]
            info += Array(id.utf8) + le32(t.count) + t + (t.count % 2 == 1 ? [0] : [])
        }
        let list = Array("LIST".utf8) + le32(info.count) + info
        let samples = values(frames: 100, channels: 2, bits: 16)
        let d = try PCMFileDecoder(source: MemoryByteSource(data: makeWAV(rate: 44100, channels: 2, bits: 16, samples: samples, list: list)))
        XCTAssertEqual(d.tags["ARTIST"], "Glenn Gould")
        XCTAssertEqual(d.tags["ALBUM"], "Goldberg Variations")
        XCTAssertEqual(d.tags["GENRE"], "Classical")
    }

    func testWAVSeek() throws {
        let samples = values(frames: 44100 * 3, channels: 2, bits: 16)
        let d = try PCMFileDecoder(source: MemoryByteSource(data: makeWAV(rate: 44100, channels: 2, bits: 16, samples: samples)))
        for sec in [2.0, 0.5, 1.25, 0.0] {
            try d.seek(toSeconds: sec)
            let s = try XCTUnwrap(try d.nextSamples())
            let target = Int(sec * 44100)
            XCTAssertEqual(s[0], Float(samples[target * 2]) / 32768)
            XCTAssertEqual(s[1], Float(samples[target * 2 + 1]) / 32768)
        }
        try d.seek(toSeconds: 100)                      // past the end
        XCTAssertNil(try d.nextSamples())
    }

    func testWAVTruncatedDataStillPlaysWhatIsThere() throws {
        let samples = values(frames: 4000, channels: 2, bits: 16)
        var wav = makeWAV(rate: 44100, channels: 2, bits: 16, samples: samples)
        wav = wav.prefix(wav.count - 4000).map { $0 }.withUnsafeBytes { Data($0) }     // cut the tail
        let d = try PCMFileDecoder(source: MemoryByteSource(data: wav))
        let got = try decodeAll(d)
        XCTAssertGreaterThan(got.count, 0)
        XCTAssertLessThan(got.count, 4000 * 2)
    }

    func testWAVRejectsMoreThanTwoChannels() {
        let samples = values(frames: 100, channels: 6, bits: 16)
        XCTAssertThrowsError(try PCMFileDecoder(source: MemoryByteSource(data: makeWAV(rate: 48000, channels: 6, bits: 16, samples: samples))))
    }

    // MARK: - AIFF

    func testAIFFStereo16_24() throws {
        for bits in [16, 24] {
            let samples = values(frames: 10000, channels: 2, bits: bits)
            let d = try PCMFileDecoder(source: MemoryByteSource(data: makeAIFF(rate: 88200, channels: 2, bits: bits, samples: samples)))
            XCTAssertEqual(d.sampleRate, 88200)
            try check(d, channels: 2, bits: bits, samples: samples)
        }
    }

    func testAIFFSampleRateExtendedFloat() throws {
        for rate in [44100, 48000, 96000, 176400, 192000] {
            let samples = values(frames: 10, channels: 2, bits: 16)
            let d = try PCMFileDecoder(source: MemoryByteSource(data: makeAIFF(rate: rate, channels: 2, bits: 16, samples: samples)))
            XCTAssertEqual(d.sampleRate, rate)
        }
    }

    func testAIFFSeek() throws {
        let samples = values(frames: 44100 * 2, channels: 2, bits: 24)
        let d = try PCMFileDecoder(source: MemoryByteSource(data: makeAIFF(rate: 44100, channels: 2, bits: 24, samples: samples)))
        try d.seek(toSeconds: 1.5)
        let s = try XCTUnwrap(try d.nextSamples())
        let target = Int(1.5 * 44100)
        XCTAssertEqual(s[0], Float(samples[target * 2]) / 8_388_608)
    }

    func testRejectsOtherFiles() {
        XCTAssertThrowsError(try PCMFileDecoder(source: MemoryByteSource(data: Data(repeating: 1, count: 200))))
    }
}
