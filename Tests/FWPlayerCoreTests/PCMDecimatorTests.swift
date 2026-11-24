import XCTest
@testable import FWPlayerCore

/// The integer-ratio rate reduction used when the output device runs at a fraction of a file's rate.
final class PCMDecimatorTests: XCTestCase {

    private func sine(frequency: Double, rate: Double, frames: Int, amplitude: Float = 1) -> [Float] {
        var out = [Float](repeating: 0, count: frames * 2)
        for n in 0..<frames {
            let v = amplitude * Float(sin(2 * Double.pi * frequency * Double(n) / rate))
            out[2 * n] = v
            out[2 * n + 1] = v
        }
        return out
    }

    private func peak(_ x: [Float], from frame: Int) -> Float {
        stride(from: frame * 2, to: x.count, by: 2).map { abs(x[$0]) }.max() ?? 0
    }

    func testFactorIsAWholeNumberBetweenTwoAndEight() {
        XCTAssertEqual(PCMDecimator.factor(fileRate: 192000, hardwareRate: 96000), 2)
        XCTAssertEqual(PCMDecimator.factor(fileRate: 176400, hardwareRate: 44100), 4)
        XCTAssertEqual(PCMDecimator.factor(fileRate: 96000, hardwareRate: 96000), 1)
        XCTAssertEqual(PCMDecimator.factor(fileRate: 44100, hardwareRate: 96000), 1)       // never up
        XCTAssertEqual(PCMDecimator.factor(fileRate: 192000, hardwareRate: 44100), 1)      // not a whole ratio
        XCTAssertEqual(PCMDecimator.factor(fileRate: 192000, hardwareRate: nil), 1)
        XCTAssertEqual(PCMDecimator.factor(fileRate: 192000, hardwareRate: 0), 1)
    }

    func testLevelIsUntouchedInThePassband() {
        let dc = PCMDecimator(factor: 2)
        let out = dc.process([Float](repeating: 0.5, count: 2 * 4000))
        // After the filter has filled, a constant stays exactly that constant.
        XCTAssertEqual(out[out.count - 2], 0.5, accuracy: 1e-4)

        let tone = PCMDecimator(factor: 2).process(sine(frequency: 1000, rate: 192000, frames: 8000))
        XCTAssertEqual(peak(tone, from: 400), 1, accuracy: 0.01)                            // 1 kHz keeps its level
    }

    func testOutputIsHalfAsLong() {
        let out = PCMDecimator(factor: 2).process([Float](repeating: 0.1, count: 2 * 10000))
        let frames = out.count / 2
        XCTAssertTrue((4800...5200).contains(frames), "got \(frames)")
    }

    func testContentAboveTheNewNyquistIsRemoved() {
        // 60 kHz at 192 kHz is above the 48 kHz limit of a 96 kHz output; unfiltered it would alias to 36 kHz.
        let out = PCMDecimator(factor: 2).process(sine(frequency: 60000, rate: 192000, frames: 8000))
        XCTAssertLessThan(peak(out, from: 400), 0.002)                                      // > 54 dB down
    }

    func testChunkSizeDoesNotChangeTheResult() {
        let input = sine(frequency: 3000, rate: 192000, frames: 5000)
        let whole = PCMDecimator(factor: 2).process(input)
        let pieces = PCMDecimator(factor: 2)
        var chunked = [Float]()
        var start = 0
        for size in [1, 7, 1000, 333, 2000, 1659] {          // frames; sums to 5000
            let end = start + size * 2
            chunked += pieces.process(Array(input[start..<end]))
            start = end
        }
        XCTAssertEqual(start, input.count)
        XCTAssertEqual(whole.count, chunked.count)
        for i in 0..<whole.count { XCTAssertEqual(whole[i], chunked[i], accuracy: 1e-5) }
    }

    func testFinishFlushesTheTailOnceAndResetStartsOver() {
        let d = PCMDecimator(factor: 2)
        _ = d.process([Float](repeating: 1, count: 2 * 1000))
        let tail = d.finish()
        XCTAssertFalse(tail.isEmpty)
        XCTAssertTrue(d.finish().isEmpty)                    // only once
        d.reset()
        XCTAssertFalse(d.finish().isEmpty)                   // after a seek it can flush again
    }

    func testDecimatedSourceReportsTheLowerRateAndSameDuration() throws {
        var remaining = 3
        let source = PCMSource(sampleRate: 192000, durationSeconds: 2.5, label: "FLAC",
                               next: {
                                   guard remaining > 0 else { return nil }
                                   remaining -= 1
                                   return [Float](repeating: 0.25, count: 2 * 4000)
                               },
                               seek: { _ in remaining = 3 })
        let half = source.decimated(by: 2)
        XCTAssertEqual(half.sampleRate, 96000)
        XCTAssertEqual(half.durationSeconds, 2.5)
        var frames = 0
        while let chunk = try half.next() { frames += chunk.count / 2 }
        XCTAssertTrue((5900...6300).contains(frames), "got \(frames)")                      // ~12000 / 2, plus the tail
        try half.seek(0)
        XCTAssertNotNil(try half.next())                                                    // reads again after a seek
    }
}
