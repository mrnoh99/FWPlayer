import XCTest
@testable import FWPlayerCore

final class LRUCacheTests: XCTestCase {
    func testDropsTheLeastRecentlyUsedOverTheLimit() {
        var cache = LRUCache<String, Int>(costLimit: 30)
        cache.set(1, cost: 10, for: "a")
        cache.set(2, cost: 10, for: "b")
        cache.set(3, cost: 10, for: "c")
        XCTAssertEqual(cache.value(for: "a"), 1)            // "a" is now the most recent
        XCTAssertEqual(cache.set(4, cost: 10, for: "d"), ["b"])
        XCTAssertNil(cache.value(for: "b"))
        XCTAssertEqual(cache.count, 3)
        XCTAssertEqual(cache.totalCost, 30)
    }

    func testDropsAsManyAsNeeded() {
        var cache = LRUCache<String, Int>(costLimit: 30)
        cache.set(1, cost: 10, for: "a")
        cache.set(2, cost: 10, for: "b")
        cache.set(3, cost: 10, for: "c")
        XCTAssertEqual(cache.set(4, cost: 15, for: "d"), ["a", "b"])   // 45 → 35 → 25
        XCTAssertEqual(cache.totalCost, 25)
    }

    func testTheNewValueStaysEvenWhenItAloneIsOverTheLimit() {
        var cache = LRUCache<String, Int>(costLimit: 10)
        cache.set(1, cost: 5, for: "a")
        XCTAssertEqual(cache.set(2, cost: 50, for: "big"), ["a"])
        XCTAssertEqual(cache.value(for: "big"), 2)
    }

    func testReplacingAValueReplacesItsCost() {
        var cache = LRUCache<String, Int>(costLimit: 100)
        cache.set(1, cost: 40, for: "a")
        cache.set(2, cost: 10, for: "a")
        XCTAssertEqual(cache.totalCost, 10)
        XCTAssertEqual(cache.value(for: "a"), 2)
        XCTAssertTrue(cache.contains("a"))
        cache.removeAll()
        XCTAssertEqual(cache.count, 0)
        XCTAssertEqual(cache.totalCost, 0)
    }
}
