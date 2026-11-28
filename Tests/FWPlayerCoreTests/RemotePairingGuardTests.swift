import XCTest
@testable import FWPlayerCore

/// Wrong-PIN lockout and the limit on remotes waiting to pair.
final class RemotePairingGuardTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 1_000_000)

    func testFiveWrongPINsInAMinuteLockAttemptsOut() {
        var guardian = RemotePairingGuard()
        for i in 0..<4 {
            XCTAssertEqual(guardian.recordFailure(now: start + Double(i)), i + 1)
            XCTAssertFalse(guardian.isLocked(now: start + Double(i)))
        }
        guardian.recordFailure(now: start + 4)
        XCTAssertTrue(guardian.isLocked(now: start + 5))
    }

    func testTheLockoutEndsWhenTheMinuteIsUp() {
        var guardian = RemotePairingGuard()
        for i in 0..<5 { guardian.recordFailure(now: start + Double(i)) }
        XCTAssertTrue(guardian.isLocked(now: start + 30))
        XCTAssertFalse(guardian.isLocked(now: start + 61))   // the first failure has aged out
        XCTAssertEqual(guardian.failureCount(now: start + 120), 0)
    }

    func testTheOldestWaitingRemotesMakeRoom() {
        let waiting = [(id: "c", since: start + 2), (id: "a", since: start), (id: "d", since: start + 3),
                       (id: "b", since: start + 1)]
        // Four may wait; with four already waiting, the oldest goes so a new one fits.
        XCTAssertEqual(RemotePairingGuard.toDrop(waiting: waiting, maxUnpaired: 4), ["a"])
        XCTAssertEqual(RemotePairingGuard.toDrop(waiting: waiting, maxUnpaired: 2), ["a", "b", "c"])
        XCTAssertEqual(RemotePairingGuard.toDrop(waiting: Array(waiting.prefix(2)), maxUnpaired: 4), [])
        XCTAssertEqual(RemotePairingGuard.toDrop(waiting: [(id: "x", since: start)], maxUnpaired: 1), ["x"])
    }
}
