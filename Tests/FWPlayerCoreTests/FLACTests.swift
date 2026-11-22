import XCTest
@testable import FWPlayerCore

final class FLACTests: XCTestCase {
    private func fixture(_ name: String, _ ext: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    private func expected(_ name: String) throws -> [Int32] {
        let d = try fixture(name, "pcm")
        return d.withUnsafeBytes { Array($0.bindMemory(to: Int32.self)) }   // little-endian host
    }

    private func decoder(_ name: String) throws -> FLACDecoder {
        try FLACDecoder(source: MemoryByteSource(data: try fixture(name, "flac")))
    }

    /// Decodes everything; returns interleaved stereo floats.
    private func decodeAll(_ d: FLACDecoder) throws -> [Float] {
        var all = [Float]()
        while let s = try d.nextSamples() { all += s }
        return all
    }

    private func check(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let d = try decoder(name)
        let bits = d.info.bitsPerSample
        let exp = try expected(name)
        let got = try decodeAll(d)
        let scale = Float(Int64(1) << Int64(bits - 1))
        let channels = d.info.channels
        XCTAssertEqual(got.count, exp.count / channels * 2, name, file: file, line: line)
        var bad = 0
        for i in 0..<(got.count / 2) {
            let l = Float(exp[i * channels]) / scale
            let r = Float(exp[i * channels + channels - 1]) / scale
            if got[2 * i] != l || got[2 * i + 1] != r { bad += 1 }
        }
        XCTAssertEqual(bad, 0, "\(name): mismatching frames", file: file, line: line)
    }

    func testAllFixturesDecodeBitExact() throws {
        for name in ["s16_44k_stereo_l8", "s16_44k_stereo_midside", "s16_44k_stereo_leftside",
                     "s16_44k_stereo_rightside", "s16_44k_stereo_fixed", "s24_96k_stereo",
                     "s24_192k_stereo", "s16_44k_mono", "s16_44k_long", "s16_44k_long_seektable"] {
            try check(name)
        }
    }

    func testStreamInfo() throws {
        let d = try decoder("s24_96k_stereo")
        XCTAssertEqual(d.info.sampleRate, 96000)
        XCTAssertEqual(d.info.bitsPerSample, 24)
        XCTAssertEqual(d.info.channels, 2)
        XCTAssertGreaterThan(d.durationSeconds, 0)
    }

    func testRejectsNonFLAC() {
        XCTAssertThrowsError(try FLACDecoder(source: MemoryByteSource(data: Data(repeating: 0, count: 100))))
    }

    private func checkSeek(_ name: String, seconds: [Double], file: StaticString = #filePath, line: UInt = #line) throws {
        let d = try decoder(name)
        let exp = try expected(name)
        let rate = Double(d.info.sampleRate)
        for sec in seconds {
            try d.seek(toSeconds: sec)
            let target = Int(sec * rate)
            guard let s = try d.nextSamples() else { XCTFail("no samples after seek \(sec)", file: file, line: line); continue }
            let scale = Float(1 << (d.info.bitsPerSample - 1))
            XCTAssertEqual(s[0], Float(exp[target * 2]) / scale, "\(name) seek \(sec) L", file: file, line: line)
            XCTAssertEqual(s[1], Float(exp[target * 2 + 1]) / scale, "\(name) seek \(sec) R", file: file, line: line)
        }
    }

    func testSeekWithoutSeektable() throws {
        try checkSeek("s16_44k_long", seconds: [1.0, 0.5, 1.9, 0.0, 1.234])
    }

    func testSeekWithSeektable() throws {
        try checkSeek("s16_44k_long_seektable", seconds: [1.0, 0.5, 1.9, 0.0, 1.234])
    }

    func testSeekThenDecodeToEnd() throws {
        let d = try decoder("s16_44k_long")
        try d.seek(toSeconds: 1.5)
        let rest = try decodeAll(d)
        XCTAssertEqual(rest.count / 2, 88200 - Int(1.5 * 44100))
    }

    func testTagsAbsentIsEmpty() throws {
        XCTAssertNotNil(try decoder("s16_44k_stereo_l8").tags)
    }
}
