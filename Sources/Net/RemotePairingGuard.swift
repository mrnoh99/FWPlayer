import Foundation

/// The rules for remotes that haven't paired yet, kept apart from the network code so
/// they can be tested: how many wrong PINs lock attempts out, and which waiting remotes
/// make room for a new one.
struct RemotePairingGuard {
    /// Wrong PINs allowed per minute; past this every attempt is refused until the
    /// minute is up, so the 4-digit PIN can't be found by trying them all.
    static let maxFailuresPerMinute = 5
    /// Unpaired remotes that may wait at once.
    static let maxUnpaired = 4

    private var recentFailures: [Date] = []

    /// Wrong PINs in the last minute.
    mutating func failureCount(now: Date = Date()) -> Int {
        recentFailures.removeAll { now.timeIntervalSince($0) > 60 }
        return recentFailures.count
    }

    /// Whether PIN attempts are refused for now.
    mutating func isLocked(now: Date = Date()) -> Bool {
        failureCount(now: now) >= Self.maxFailuresPerMinute
    }

    /// Notes a wrong PIN; returns how many there have been in the last minute.
    @discardableResult
    mutating func recordFailure(now: Date = Date()) -> Int {
        recentFailures.append(now)
        return failureCount(now: now)
    }

    /// The waiting remotes to disconnect, oldest first, so that one more fits within
    /// `maxUnpaired`.
    static func toDrop<ID>(waiting: [(id: ID, since: Date)], maxUnpaired: Int = maxUnpaired) -> [ID] {
        let room = max(0, maxUnpaired - 1)
        return waiting.sorted { $0.since < $1.since }.dropLast(room).map(\.id)
    }
}
