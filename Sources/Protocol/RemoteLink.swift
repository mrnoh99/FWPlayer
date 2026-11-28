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
    /// The largest frame accepted; a bigger length closes the connection, so a peer can't
    /// make us buffer without bound. Touched only on `queue`.
    private var maxFrameLength = RemoteLink.defaultMaxFrameLength
    /// Room for a large library, listing or queue.
    static let defaultMaxFrameLength = 64 << 20
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

    /// Changes the largest frame accepted from the peer (e.g. small until it has paired).
    func setMaxFrameLength(_ length: Int) {
        queue.async { self.maxFrameLength = length }
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
                guard self.drain() else {
                    self.buffer.removeAll()
                    self.connection.cancel()
                    return
                }
            }
            if isComplete || error != nil {
                self.connection.cancel()
                return
            }
            self.receive()
        }
    }

    /// What the start of the receive buffer holds.
    enum FrameStatus: Equatable {
        /// Not a whole frame yet.
        case incomplete
        /// A whole frame whose JSON is this many bytes, after the 4-byte length.
        case frame(length: Int)
        /// A frame longer than allowed.
        case tooLarge
    }

    static func frameStatus(of buffer: Data, maxLength: Int) -> FrameStatus {
        guard buffer.count >= 4 else { return .incomplete }
        let bytes = [UInt8](buffer.prefix(4))
        let length = Int(bytes[0]) << 24 | Int(bytes[1]) << 16 | Int(bytes[2]) << 8 | Int(bytes[3])
        guard length <= maxLength else { return .tooLarge }
        return buffer.count >= 4 + length ? .frame(length: length) : .incomplete
    }

    /// Pulls every complete frame out of `buffer` and dispatches it. False when the
    /// peer broke the protocol (an oversized frame) and the connection should close.
    private func drain() -> Bool {
        while true {
            let length: Int
            switch Self.frameStatus(of: buffer, maxLength: maxFrameLength) {
            case .incomplete: return true
            case .tooLarge:
                NSLog("[RemoteLink] frame over \(maxFrameLength) bytes; closing the connection")
                return false
            case .frame(let frameLength): length = frameLength
            }
            let start = buffer.startIndex
            let payload = buffer.subdata(in: start + 4 ..< start + 4 + length)
            buffer.removeSubrange(start ..< start + 4 + length)
            let message: RemoteMessage
            do {
                message = try decoder.decode(RemoteMessage.self, from: payload)
            } catch {
                // A frame we can't decode is dropped (never corrupts the stream —
                // the bytes were already consumed). Log it so a cross-version wire
                // mismatch is diagnosable instead of silently vanishing.
                let preview = String(data: payload.prefix(200), encoding: .utf8) ?? "<non-utf8>"
                NSLog("[RemoteLink] dropped undecodable frame (\(payload.count) bytes): \(error) — \(preview)")
                continue
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                MainActor.assumeIsolated { self.onMessage?(message) }
            }
        }
    }
}
