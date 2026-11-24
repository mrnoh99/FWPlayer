import Foundation

/// Integer-ratio sample-rate reduction (e.g. 192 kHz → 96 kHz) with a long linear-phase
/// low-pass filter, done before the audio engine instead of leaving it to the system's
/// converter. Passband gain is exactly 1 (the filter's taps sum to 1), so the level is untouched.
///
/// Used when the output device can't run at the file's rate but runs at an integer fraction
/// of it. Works on interleaved stereo; feed it any chunk sizes.
final class PCMDecimator {
    let factor: Int
    private let taps: [Float]
    private var work: [Float]                 // interleaved L,R: the filter history, then new input
    private var position: Int                 // frame index in `work` of the next output's newest input
    private var flushed = false

    /// The factor to reduce `fileRate` to `hardwareRate`, or 1 if that isn't a whole number from 2 to 8
    /// (or the hardware rate is unknown or not lower).
    static func factor(fileRate: Double, hardwareRate: Double?) -> Int {
        guard let hardwareRate, hardwareRate > 0, fileRate > hardwareRate else { return 1 }
        let ratio = fileRate / hardwareRate
        let whole = ratio.rounded()
        guard whole >= 2, whole <= 8, abs(ratio - whole) < 0.001 else { return 1 }
        return Int(whole)
    }

    init(factor: Int) {
        precondition(factor >= 2)
        self.factor = factor
        taps = Self.lowPass(factor: factor)
        work = [Float](repeating: 0, count: (taps.count - 1) * 2)
        position = taps.count - 1
    }

    /// Passband edge at 0.43, stopband from 0.5 of the *output* rate, about 90 dB down.
    private static func lowPass(factor: Int) -> [Float] {
        let count = 82 * factor + 1           // odd: a whole-sample delay
        let cutoff = 0.465 / Double(factor)   // cycles per input sample, mid-transition
        let beta = 8.96                       // Kaiser, ~90 dB stopband
        let mid = Double(count - 1) / 2
        var h = [Double](repeating: 0, count: count)
        for n in 0..<count {
            let x = Double(n) - mid
            let sinc = x == 0 ? 2 * cutoff : sin(2 * Double.pi * cutoff * x) / (Double.pi * x)
            let r = x / mid
            let window = besselI0(beta * (1 - r * r).squareRoot()) / besselI0(beta)
            h[n] = sinc * window
        }
        let sum = h.reduce(0, +)
        return h.map { Float($0 / sum) }
    }

    private static func besselI0(_ x: Double) -> Double {
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

    /// Reduces the next run of interleaved stereo input. Returns the output frames that are ready.
    func process(_ input: [Float]) -> [Float] {
        work.append(contentsOf: input)
        return drain()
    }

    /// The tail: the filter's delay worth of silence pushed through so the last samples come out.
    func finish() -> [Float] {
        guard !flushed else { return [] }
        flushed = true
        work.append(contentsOf: [Float](repeating: 0, count: (taps.count - 1) / 2 * 2))
        return drain()
    }

    /// Forgets the history (after a seek).
    func reset() {
        work = [Float](repeating: 0, count: (taps.count - 1) * 2)
        position = taps.count - 1
        flushed = false
    }

    private func drain() -> [Float] {
        let frames = work.count / 2
        let count = taps.count
        var out = [Float]()
        out.reserveCapacity(max(0, (frames - position) / factor + 1) * 2)
        work.withUnsafeBufferPointer { w in
            taps.withUnsafeBufferPointer { h in
                while position < frames {
                    var l: Float = 0, r: Float = 0
                    let base = position
                    for j in 0..<count {
                        let at = 2 * (base - j)
                        let tap = h[j]
                        l += tap * w[at]
                        r += tap * w[at + 1]
                    }
                    out.append(l)
                    out.append(r)
                    position += factor
                }
            }
        }
        // Keep only the history the next output still needs.
        let drop = max(0, position - (count - 1))
        if drop > 0 {
            work.removeFirst(drop * 2)
            position -= drop
        }
        return out
    }
}

extension PCMSource {
    /// This source at 1/`factor` of its sample rate (same length in seconds).
    func decimated(by factor: Int) -> PCMSource {
        let decimator = PCMDecimator(factor: factor)
        return PCMSource(
            sampleRate: sampleRate / Double(factor), durationSeconds: durationSeconds, label: label,
            next: {
                while true {
                    if let chunk = try self.next() {
                        let out = decimator.process(chunk)
                        if !out.isEmpty { return out }      // a tiny chunk can yield nothing yet
                    } else {
                        let tail = decimator.finish()
                        return tail.isEmpty ? nil : tail
                    }
                }
            },
            seek: { seconds in
                decimator.reset()
                try self.seek(seconds)
            })
    }
}
