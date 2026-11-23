import XCTest
@testable import FWPlayerCore

final class DiagnosticsLogTests: XCTestCase {
    func testKeepsTheNewestEntriesWithinCapacity() {
        let log = DiagnosticsLog(capacity: 5)
        for i in 1...12 { log.log("t", "event \(i)") }
        XCTAssertEqual(log.count, 5)
        XCTAssertEqual(log.snapshot().first?.message, "event 8")
        XCTAssertEqual(log.snapshot().last?.message, "event 12")
    }

    func testTextHasOneLinePerEventWithCategory() {
        let log = DiagnosticsLog()
        log.log("play", "load song")
        log.log("rate", "asked for 96000 Hz")
        let lines = log.text().split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("[play] load song"))
        XCTAssertTrue(lines[1].contains("[rate] asked for 96000 Hz"))
    }

    func testClearEmptiesTheLog() {
        let log = DiagnosticsLog()
        log.log("a", "b")
        log.clear()
        XCTAssertEqual(log.count, 0)
        XCTAssertEqual(log.text(), "")
    }

    func testIsSafeToWriteFromManyThreads() {
        let log = DiagnosticsLog(capacity: 1000)
        DispatchQueue.concurrentPerform(iterations: 8) { t in
            for i in 0..<100 { log.log("thread\(t)", "event \(i)") }
        }
        XCTAssertEqual(log.count, 800)
    }
}
