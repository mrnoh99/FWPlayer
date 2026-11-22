import XCTest
@testable import FWPlayerCore

/// Tests for the live DSD renderer (the part of instant DSD playback that runs in the
/// audio callback) and for seeking in the DSD readers.
final class DSDLiveTests: XCTestCase {

    // MARK: - Helpers

    private func render(_ renderer: DSDLiveRenderer, _ frames: Int) -> (left: [Float], right: [Float]) {
        var l = [Float](repeating: 9, count: frames)
        var r = [Float](repeating: 9, count: frames)
        l.withUnsafeMutableBufferPointer { lp in
            r.withUnsafeMutableBufferPointer { rp in
                renderer.render(frames: frames, left: lp.baseAddress!, right: rp.baseAddress!)
            }
        }
        return (l, r)
    }

    /// The 24-bit DoP word a rendered float stands for.
    private func word(_ x: Float) -> UInt32 {
        UInt32(bitPattern: Int32((x * 8_388_608).rounded())) & 0xFF_FFFF
    }
    private func marker(_ x: Float) -> UInt32 { word(x) >> 16 }
    private func bits(_ x: Float) -> UInt32 { word(x) & 0xFFFF }

    /// A renderer with a 100-frame lead/tail silence (sample rate 1000 Hz, 0.1 s).
    private func makeRenderer(doP: Bool = true) -> DSDLiveRenderer {
        DSDLiveRenderer(isDoP: doP, sampleRate: 1000, capacitySeconds: 8, silenceSeconds: 0.1)
    }

    // MARK: - DoP

    func testDoPMarkersAlternateAndBitsSurviveExactly() {
        let renderer = makeRenderer()
        let units: [Float] = [0x1234, 0xABCD, 0x0000, 0xFFFF, 0x6969, 0x8001]       // 3 frames, L/R
        XCTAssertEqual(renderer.push(units), 3)
        renderer.setPaused(false)

        let out = render(renderer, 100 + 3 + 5)
        for f in 0..<out.left.count {
            let expected: UInt32 = f % 2 == 0 ? 0x05 : 0xFA
            XCTAssertEqual(marker(out.left[f]), expected, "left marker, frame \\(f)")
            XCTAssertEqual(marker(out.right[f]), expected, "right marker, frame \\(f)")
        }
        // Lead-in is DSD silence.
        XCTAssertEqual(bits(out.left[0]), 0x6969)
        XCTAssertEqual(bits(out.right[99]), 0x6969)
        // The music: exact 16-bit units.
        XCTAssertEqual(bits(out.left[100]), 0x1234)
        XCTAssertEqual(bits(out.right[100]), 0xABCD)
        XCTAssertEqual(bits(out.left[101]), 0x0000)
        XCTAssertEqual(bits(out.right[101]), 0xFFFF)
        XCTAssertEqual(bits(out.left[102]), 0x6969)
        XCTAssertEqual(bits(out.right[102]), 0x8001)
        // After the music, with no more data: DSD silence again (an under-run).
        XCTAssertEqual(bits(out.left[103]), 0x6969)
        XCTAssertEqual(marker(out.left[107]), 107 % 2 == 0 ? 0x05 : 0xFA)
    }

    func testPausingKeepsSendingDSDSilenceWithContinuousMarkers() {
        let renderer = makeRenderer()
        renderer.push([Float](repeating: 0x1111, count: 2 * 300))
        renderer.setPaused(false)
        let first = render(renderer, 150)                      // lead-in + 50 music frames
        let positionBefore = renderer.musicSeconds
        XCTAssertEqual(positionBefore, 0.05, accuracy: 1e-9)

        renderer.setPaused(true)
        let paused = render(renderer, 40)
        for f in 0..<40 {
            XCTAssertEqual(bits(paused.left[f]), 0x6969)
            let overall = 150 + f
            XCTAssertEqual(marker(paused.left[f]), overall % 2 == 0 ? 0x05 : 0xFA, "marker while paused")
        }
        XCTAssertEqual(renderer.musicSeconds, positionBefore, accuracy: 1e-9, "the clock stands still when paused")

        renderer.setPaused(false)
        let resumed = render(renderer, 4)
        XCTAssertEqual(bits(resumed.left[0]), 0x1111)           // resumes where it stopped
        XCTAssertEqual(marker(resumed.left[0]), 190 % 2 == 0 ? 0x05 : 0xFA)
        _ = first
    }

    func testFlushRepositionsTheClockAndKeepsMarkersContinuous() {
        let renderer = makeRenderer()
        renderer.push([Float](repeating: 0x2222, count: 2 * 500))
        renderer.setPaused(false)
        _ = render(renderer, 130)                               // 100 lead-in + 30 music

        renderer.flush(musicSeconds: 2.0)
        XCTAssertEqual(renderer.musicSeconds, 2.0, accuracy: 1e-9)
        let after = render(renderer, 6)                         // nothing buffered: DSD silence
        for f in 0..<6 {
            XCTAssertEqual(bits(after.left[f]), 0x6969)
            XCTAssertEqual(marker(after.left[f]), (130 + f) % 2 == 0 ? 0x05 : 0xFA, "no marker break at a seek")
        }
        renderer.push([Float](repeating: 0x3333, count: 2 * 10))
        XCTAssertEqual(bits(render(renderer, 1).left[0]), 0x3333)
    }

    func testFinishedIsReportedOnceAfterTheTail() {
        let renderer = makeRenderer()
        var finished = 0
        renderer.onFinished = { finished += 1 }
        renderer.push([Float](repeating: 0x4444, count: 2 * 10))
        renderer.markEnd()
        renderer.setPaused(false)
        _ = render(renderer, 100 + 10 + 99)                     // lead-in, music, 99 of 100 tail frames
        XCTAssertEqual(finished, 0)
        _ = render(renderer, 5)
        XCTAssertEqual(finished, 1)
        _ = render(renderer, 50)
        XCTAssertEqual(finished, 1, "reported only once")
    }

    func testBufferLimitsAndUnderrunDoNotBlock() {
        let renderer = DSDLiveRenderer(isDoP: true, sampleRate: 100, capacitySeconds: 0.01, silenceSeconds: 0)
        let capacity = renderer.freeFrames
        XCTAssertGreaterThan(capacity, 0)
        XCTAssertEqual(renderer.push([Float](repeating: 1, count: 2 * (capacity + 50))), capacity)
        XCTAssertEqual(renderer.freeFrames, 0)
        renderer.setPaused(false)
        _ = render(renderer, 10)
        XCTAssertEqual(renderer.freeFrames, 10)
    }

    // MARK: - PCM

    func testPCMPassesSamplesThroughAndIsSilentOtherwise() {
        let renderer = makeRenderer(doP: false)
        renderer.push([0.25, -0.5, 0.125, 0.75])
        renderer.setPaused(false)
        let out = render(renderer, 100 + 2 + 3)
        XCTAssertEqual(out.left[0], 0)                          // lead-in
        XCTAssertEqual(out.left[100], 0.25)
        XCTAssertEqual(out.right[100], -0.5)
        XCTAssertEqual(out.left[101], 0.125)
        XCTAssertEqual(out.right[101], 0.75)
        XCTAssertEqual(out.left[102], 0)                        // under-run: plain silence
    }

    // MARK: - DoP units

    func testDoPUnitsPackBytePairsPerChannel() {
        let units = DSDLivePlayback.dopUnits(left: [0x12, 0x34, 0xAB, 0xCD], right: [0x56, 0x78, 0x01, 0x02])
        XCTAssertEqual(units, [0x1234, 0x5678, 0xABCD, 0x0102])
    }

    // MARK: - Seeking in readers

    private func le32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }
    private func le64(_ v: UInt64) -> [UInt8] { le32(UInt32(v & 0xFFFF_FFFF)) + le32(UInt32(v >> 32)) }

    /// A stereo DSD64 DSF with 8-byte blocks; left byte i = i, right byte i = 100 + i.
    private func makeDSF(bytesPerChannel: Int) throws -> URL {
        let blockSize = 8
        let left = (0..<bytesPerChannel).map { UInt8($0) }
        let right = (0..<bytesPerChannel).map { UInt8(100 + $0) }
        var data = [UInt8]()
        for g in 0..<(bytesPerChannel / blockSize) {
            data += left[(g * blockSize)..<((g + 1) * blockSize)]
            data += right[(g * blockSize)..<((g + 1) * blockSize)]
        }
        var out = [UInt8]()
        out += Array("DSD ".utf8) + le64(28) + le64(UInt64(28 + 52 + 12 + data.count)) + le64(0)
        out += Array("fmt ".utf8) + le64(52) + le32(1) + le32(0) + le32(2) + le32(2) + le32(2_822_400)
        out += le32(8) + le64(UInt64(bytesPerChannel * 8)) + le32(UInt32(blockSize)) + le32(0)
        out += Array("data".utf8) + le64(UInt64(12 + data.count)) + data
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fwtest-\(UUID().uuidString).dsf")
        try Data(out).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// The readers work over any byte source, which is what lets a file on an SMB share
    /// play straight from ranged reads.
    func testDSFReaderWorksOverAnArbitraryByteSource() throws {
        let url = try makeDSF(bytesPerChannel: 32)
        let source = MemoryByteSource(data: try Data(contentsOf: url))
        let reader = try DSDDoPDecoder.makeReader(stream: source, fileExtension: "dsf")
        XCTAssertEqual(reader.dsdRate, 2_822_400)
        let chunk = try XCTUnwrap(reader.next())
        XCTAssertEqual(chunk.left.count, 32)
        XCTAssertEqual(chunk.left.last, 31)
        XCTAssertEqual(chunk.right.first, 100)
        XCTAssertNil(try reader.next())
    }

    func testByteStreamHandleBehavesLikeAFileCursor() throws {
        let handle = ByteStreamHandle(MemoryByteSource(bytes: Array(0..<10)))
        XCTAssertEqual(try handle.seekToEnd(), 10)
        XCTAssertNil(try handle.read(upToCount: 4))
        try handle.seek(toOffset: 8)
        XCTAssertEqual(Array(try XCTUnwrap(handle.read(upToCount: 5))), [8, 9])
        try handle.seek(toOffset: 2)
        XCTAssertEqual(Array(try XCTUnwrap(handle.read(upToCount: 3))), [2, 3, 4])
        XCTAssertEqual(Array(try XCTUnwrap(handle.read(upToCount: 2))), [5, 6])
    }

    func testDSFSeekLandsOnAnEvenByteAndKeepsTheRest() throws {
        let reader = try DSDDoPDecoder.makeReader(sourceURL: try makeDSF(bytesPerChannel: 32))
        XCTAssertEqual(reader.durationSeconds, 32.0 * 8 / 2_822_400, accuracy: 1e-12)

        try reader.seek(toSeconds: 6.5 / 352_800)               // byte 6 (even)
        var chunk = try XCTUnwrap(reader.next())
        XCTAssertEqual(chunk.left.first, 6)
        XCTAssertEqual(chunk.right.first, 106)
        XCTAssertEqual(chunk.left.count, 26)

        try reader.seek(toSeconds: 10.5 / 352_800)              // byte 10: second block, skip 2
        chunk = try XCTUnwrap(reader.next())
        XCTAssertEqual(chunk.left.first, 10)
        XCTAssertEqual(chunk.left.count, 22)

        try reader.seek(toSeconds: 0)
        chunk = try XCTUnwrap(reader.next())
        XCTAssertEqual(chunk.left.count, 32)
        XCTAssertNil(try reader.next())
    }
}
