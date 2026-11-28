import Foundation

/// Values kept within a total cost, dropping the least recently used first when it is
/// exceeded. Reading a value counts as using it.
struct LRUCache<Key: Hashable, Value> {
    let costLimit: Int
    private(set) var totalCost = 0
    private var entries: [Key: Entry] = [:]
    private var clock: UInt64 = 0

    private struct Entry {
        var value: Value
        var cost: Int
        var lastUse: UInt64
    }

    init(costLimit: Int) {
        self.costLimit = costLimit
    }

    var count: Int { entries.count }

    func contains(_ key: Key) -> Bool { entries[key] != nil }

    /// The value for `key`, marked as just used.
    mutating func value(for key: Key) -> Value? {
        guard entries[key] != nil else { return nil }
        clock &+= 1
        entries[key]!.lastUse = clock
        return entries[key]!.value
    }

    /// Stores a value; returns the keys dropped to stay within the limit. The value just
    /// stored is never dropped, even when it alone is over the limit.
    @discardableResult
    mutating func set(_ value: Value, cost: Int, for key: Key) -> [Key] {
        clock &+= 1
        if let old = entries[key] { totalCost -= old.cost }
        entries[key] = Entry(value: value, cost: max(0, cost), lastUse: clock)
        totalCost += max(0, cost)
        var dropped: [Key] = []
        while totalCost > costLimit, entries.count > 1,
              let oldest = entries.filter({ $0.key != key }).min(by: { $0.value.lastUse < $1.value.lastUse }) {
            totalCost -= oldest.value.cost
            entries[oldest.key] = nil
            dropped.append(oldest.key)
        }
        return dropped
    }

    mutating func removeAll() {
        entries.removeAll()
        totalCost = 0
    }
}
