import Foundation

// MARK: - Random access to the bytes of a file, wherever it lives
//
// The DSD readers (DSF, DFF, SACD images) only need "read N bytes at offset X". By
// reading through this interface instead of a local file handle they can play a file
// on an SMB share straight from ranged network reads, with no download first.

protocol ByteSource: AnyObject, Sendable {
    /// Total length in bytes.
    var size: UInt64 { get }
    /// Reads up to `length` bytes at `offset` (fewer only at the end of the data).
    /// May block until the bytes are available.
    func read(at offset: UInt64, length: Int) throws -> Data
}

/// A local file.
final class FileByteSource: ByteSource, @unchecked Sendable {
    let size: UInt64
    private let handle: FileHandle
    private let lock = NSLock()

    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        size = try handle.seekToEnd()
    }

    deinit { try? handle.close() }

    func read(at offset: UInt64, length: Int) throws -> Data {
        guard length > 0, offset < size else { return Data() }
        lock.lock(); defer { lock.unlock() }
        try handle.seek(toOffset: offset)
        return try handle.read(upToCount: length) ?? Data()
    }
}

/// Bytes already in memory (tests, small blobs).
final class MemoryByteSource: ByteSource, @unchecked Sendable {
    private let data: Data
    var size: UInt64 { UInt64(data.count) }

    init(data: Data) { self.data = data }
    init(bytes: [UInt8]) { self.data = Data(bytes) }

    func read(at offset: UInt64, length: Int) throws -> Data {
        guard length > 0, offset < UInt64(data.count) else { return Data() }
        let start = data.startIndex + Int(offset)
        let end = min(data.endIndex, start + length)
        return Data(data[start..<end])
    }
}

/// A seekable cursor over a `ByteSource` with the handful of `FileHandle` calls the
/// readers use, so they work the same on a local file and on a network stream.
final class ByteStreamHandle: @unchecked Sendable {
    let source: ByteSource
    private var position: UInt64 = 0

    init(_ source: ByteSource) { self.source = source }

    func seek(toOffset offset: UInt64) throws { position = offset }

    @discardableResult
    func seekToEnd() throws -> UInt64 {
        position = source.size
        return position
    }

    func read(upToCount count: Int) throws -> Data? {
        let data = try source.read(at: position, length: count)
        position += UInt64(data.count)
        return data.isEmpty ? nil : data
    }

    func close() throws {}
}
