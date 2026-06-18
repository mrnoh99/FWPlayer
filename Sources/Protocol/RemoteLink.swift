import Foundation
import Network

// MARK: - Length-prefixed JSON message channel
//
// Wraps a single `NWConnection` and turns its raw byte stream into a stream of
// `RemoteMessage` values. Each frame on the wire is a 4-byte big-endian length
// followed by that many bytes of JSON. This file is IDENTICAL in the FWPlayer
// and FWPlayerRemote projects; keep them in sync.

/// A bidirectional `RemoteMessage` channel over one `NWConnection`. Used by both
/// the player (one link per connected remote) and the remote (a single link to
/// the chosen player). Callbacks are delivered on the main queue.
final class RemoteLink {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.fwplayer.remote.link")
    private var buffer = Data()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// Called on the main actor for every decoded inbound message.
    var onMessage: (@MainActor (RemoteMessage) -> Void)?
    /// Called on the main actor whenever the underlying connection changes state.
    var onStateChange: (@MainActor (NWConnection.State) -> Void)?

    init(connection: NWConnection) {
        self.connection = connection
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                guard let self else { return }
                MainActor.assumeIsolated { self.onStateChange?(state) }
            }
        }
        connection.start(queue: queue)
        receive()
    }

    func cancel() {
        connection.cancel()
    }

    /// Encodes and sends a message as a single length-prefixed frame.
    func send(_ message: RemoteMessage) {
        guard let payload = try? encoder.encode(message) else { return }
        var frame = Data()
        let length = UInt32(payload.count)
        frame.append(UInt8((length >> 24) & 0xFF))
        frame.append(UInt8((length >> 16) & 0xFF))
        frame.append(UInt8((length >> 8) & 0xFF))
        frame.append(UInt8(length & 0xFF))
        frame.append(payload)
        connection.send(content: frame, completion: .contentProcessed { _ in })
    }

    // MARK: - Receiving

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.drain()
            }
            if isComplete || error != nil {
                self.connection.cancel()
                return
            }
            self.receive()
        }
    }

    /// Pulls every complete frame out of `buffer` and dispatches it.
    private func drain() {
        while buffer.count >= 4 {
            let bytes = [UInt8](buffer.prefix(4))
            let length = (UInt32(bytes[0]) << 24)
                | (UInt32(bytes[1]) << 16)
                | (UInt32(bytes[2]) << 8)
                | UInt32(bytes[3])
            let total = 4 + Int(length)
            guard buffer.count >= total else { break }
            let payload = buffer.subdata(in: 4..<total)
            buffer.removeSubrange(0..<total)
            guard let message = try? decoder.decode(RemoteMessage.self, from: payload) else { continue }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                MainActor.assumeIsolated { self.onMessage?(message) }
            }
        }
    }
}
