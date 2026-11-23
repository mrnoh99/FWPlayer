import XCTest
@testable import FWPlayerCore

/// Tests the live playback producer without an audio device: retries on a dropped read,
/// reporting a permanent failure, and the gapless join (with seeking back into the previous
/// track). The renderer is read directly instead of through the audio engine.
final class PlaybackFlowTests: XCTestCase {
    private struct ReadError: Error, LocalizedError {
        var errorDescription: String? { "disk went away" }
    }

    /// A scripted PCM source: fails `failures` times, then yields `chunks` (frames each).
    private final class Script: @unchecked Sendable {
        private let lock = NSLock()
        private var failuresLeft: Int
        private var chunks: [Int]
        private let alwaysFail: Bool
        private(set) var seeks: [Double] = []

        init(failures: Int = 0, chunks: [Int] = [], alwaysFail: Bool = false) {
            failuresLeft = failures
            self.chunks = chunks
            self.alwaysFail = alwaysFail
        }

        func next() throws -> [Float]? {
            lock.lock(); defer { lock.unlock() }
            if alwaysFail { throw ReadError() }
            if failuresLeft > 0 { failuresLeft -= 1; throw ReadError() }
            guard !chunks.isEmpty else { return nil }
            return [Float](repeating: 0.25, count: chunks.removeFirst() * 2)
        }

        func seek(_ seconds: Double) {
            lock.lock(); seeks.append(seconds); lock.unlock()
        }

        var seekCount: Int { lock.lock(); defer { lock.unlock() }; return seeks.count }
    }

    private func source(_ script: Script, rate: Double = 1000, duration: Double = 1) -> PCMSource {
        PCMSource(sampleRate: rate, durationSeconds: duration, label: "TEST",
                  next: { try script.next() }, seek: { script.seek($0) })
    }

    private func wait(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return condition()
    }

    private func render(_ renderer: DSDLiveRenderer, _ frames: Int) {
        var l = [Float](repeating: 0, count: frames)
        var r = [Float](repeating: 0, count: frames)
        l.withUnsafeMutableBufferPointer { lp in
            r.withUnsafeMutableBufferPointer { rp in
                renderer.render(frames: frames, left: lp.baseAddress!, right: rp.baseAddress!)
            }
        }
    }

    override func setUp() {
        DSDLivePlayback.maxReadRetries = 3
        DSDLivePlayback.readRetryInterval = 0.01
    }

    override func tearDown() {
        DSDLivePlayback.maxReadRetries = 20
        DSDLivePlayback.readRetryInterval = 0.5
    }

    // MARK: - Reading

    func testPlaysEverythingTheSourceHas() {
        let backend = DSDLivePlayback(pcm: source(Script(chunks: [500, 500])))
        backend.startProducer()
        defer { backend.stop() }
        XCTAssertTrue(wait { backend.renderer.bufferedFrames == 1000 })
    }

    func testTransientReadFailuresAreRetried() {
        let backend = DSDLivePlayback(pcm: source(Script(failures: 2, chunks: [400])))
        var failed = false
        backend.onFailed = { _ in failed = true }
        backend.startProducer()
        defer { backend.stop() }
        XCTAssertTrue(wait { backend.renderer.bufferedFrames == 400 }, "the track continues after two failed reads")
        XCTAssertFalse(failed)
    }

    func testPermanentFailureIsReported() {
        let backend = DSDLivePlayback(pcm: source(Script(alwaysFail: true)))
        let reported = expectation(description: "failure reported")
        var message: String?
        backend.onFailed = {
            message = $0
            reported.fulfill()
        }
        backend.startProducer()
        defer { backend.stop() }
        wait(for: [reported], timeout: 5)
        XCTAssertTrue(message?.contains("disk went away") == true, message ?? "no message")
    }

    // MARK: - Gapless

    func testGaplessJoinMarksABoundaryAndRestartsTheClock() {
        let first = Script(chunks: [300])
        let backend = DSDLivePlayback(pcm: source(first, duration: 0.3))
        XCTAssertTrue(backend.queueNext(source(Script(chunks: [200]), duration: 0.2)))
        backend.startProducer()
        defer { backend.stop() }
        XCTAssertTrue(wait { backend.renderer.bufferedFrames == 500 })
        XCTAssertEqual(backend.renderer.pendingBoundaries, 1)

        backend.renderer.setPaused(false)
        render(backend.renderer, 310)
        XCTAssertEqual(backend.completedSegments, 1)
        XCTAssertEqual(backend.renderer.musicSeconds, 0.01, accuracy: 1e-9)       // the second track's own clock
    }

    func testOnlyASourceAtTheSameRateCanJoin() {
        let backend = DSDLivePlayback(pcm: source(Script(chunks: [10]), rate: 44100))
        XCTAssertFalse(backend.queueNext(source(Script(chunks: [10]), rate: 48000)))
        XCTAssertTrue(backend.queueNext(source(Script(chunks: [10]), rate: 44100)))
        backend.stop()
    }

    func testSeekingBackIntoThePreviousTrackRequeuesTheSuccessor() {
        let first = Script(chunks: [300])
        let second = Script(chunks: [200])
        let backend = DSDLivePlayback(pcm: source(first, duration: 0.3))
        XCTAssertTrue(backend.queueNext(source(second, duration: 0.2)))
        backend.startProducer()
        defer { backend.stop() }
        XCTAssertTrue(wait { backend.renderer.bufferedFrames == 500 })
        XCTAssertTrue(backend.wantsNext, "the successor was taken when the first track ended")
        XCTAssertEqual(backend.rewindEpoch, 0)

        backend.currentTime = 0.1                          // still in the first track: seek back into it
        XCTAssertTrue(wait { backend.rewindEpoch == 1 }, "the player is told the successor must be queued again")
        XCTAssertTrue(wait { first.seekCount >= 1 }, "the seek goes to the first track")
        XCTAssertEqual(first.seeks.first ?? -1, 0.1, accuracy: 1e-9)
        XCTAssertEqual(second.seekCount, 0, "the successor must not be seeked")
    }
}
