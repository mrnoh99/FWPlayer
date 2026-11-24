import XCTest
@testable import FWPlayerCore

/// The same song can be in the queue twice; lookups by id must pick the right copy.
final class QueueIndexTests: XCTestCase {
    func testPlayingTrackPrefersTheCurrentPosition() {
        let ids = ["a", "b", "a", "c"]
        XCTAssertEqual(QueueIndex.ofPlaying(id: "a", in: ids, current: 2), 2)
        XCTAssertEqual(QueueIndex.ofPlaying(id: "a", in: ids, current: 0), 0)
    }

    func testPlayingTrackFallsBackToTheFirstCopy() {
        let ids = ["a", "b", "a"]
        XCTAssertEqual(QueueIndex.ofPlaying(id: "a", in: ids, current: 1), 0)   // current holds another song
        XCTAssertEqual(QueueIndex.ofPlaying(id: "a", in: ids, current: nil), 0)
        XCTAssertNil(QueueIndex.ofPlaying(id: "z", in: ids, current: 1))
    }

    func testGaplessMovesOnToTheSecondCopyOfTheSameSong() {
        // Playing index 3 ("a"); the next entry, also "a", was queued at 4. The old lookup found
        // index 0 or 3 and the queue never advanced.
        let ids = ["a", "b", "c", "a", "a", "d"]
        XCTAssertEqual(QueueIndex.ofGaplessNext(id: "a", queuedAt: 4, in: ids, current: 3), 4)
    }

    func testGaplessFindsTheNearestCopyAfterTheQueueWasEdited() {
        // The queue was reordered after the next track was queued: its old position holds another song.
        let ids = ["a", "x", "b", "a", "a"]
        XCTAssertEqual(QueueIndex.ofGaplessNext(id: "a", queuedAt: 1, in: ids, current: 2), 3)
        XCTAssertEqual(QueueIndex.ofGaplessNext(id: "a", queuedAt: 9, in: ids, current: 4), 0)   // none after: first copy
        XCTAssertNil(QueueIndex.ofGaplessNext(id: "q", queuedAt: 1, in: ids, current: 0))
    }
}
