import Foundation

/// A small in-memory log of the events that explain why playback behaved the way it did
/// (which path a track took, a stream that couldn't open, a read that was retried, a rate
/// the output wouldn't follow). It can be copied from Settings and sent along with a report,
/// so a problem seen on a device can be understood without a debugger.
final class DiagnosticsLog: @unchecked Sendable {
    static let shared = DiagnosticsLog()

    struct Entry {
        let date: Date
        let category: String
        let message: String
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    private let capacity: Int

    init(capacity: Int = 400) {
        self.capacity = capacity
    }

    /// Records an event; the oldest entries drop off once `capacity` is reached.
    func log(_ category: String, _ message: String) {
        lock.lock()
        entries.append(Entry(date: Date(), category: category, message: message))
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
        lock.unlock()
    }

    static func log(_ category: String, _ message: String) {
        shared.log(category, message)
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return entries.count
    }

    func snapshot() -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        return entries
    }

    func clear() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }

    /// The whole log as plain text, oldest first, one line per event.
    func text() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return snapshot()
            .map { "\(formatter.string(from: $0.date)) [\($0.category)] \($0.message)" }
            .joined(separator: "\n")
    }
}
