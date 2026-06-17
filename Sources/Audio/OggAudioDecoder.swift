import Foundation

// MARK: - Ogg Vorbis / Opus decoder
//
// Integrated through the standard Xiph C libraries:
//   • Ogg Vorbis  → libvorbisfile  (module `CVorbis`,  ov_* API)
//   • Opus        → libopusfile    (module `COpus`,    op_* API)
//
// The whole file compiles only when at least one of those modules is available,
// mirroring how SMB support is gated on `SMBClient`. To enable it, add a SwiftPM
// package that vends the `CVorbis` and/or `COpus` system-library modules (see
// README) — no code changes are needed here.

#if canImport(COpus) || canImport(CVorbis)

#if canImport(CVorbis)
import CVorbis
#endif
#if canImport(COpus)
import COpus
#endif

/// Decodes Ogg Vorbis and Opus files to 16-bit PCM WAV for system playback.
struct OggAudioDecoder: AudioDecoder {
    static var supportedExtensions: Set<String> {
        var exts = Set<String>()
        #if canImport(CVorbis)
        exts.formUnion(["ogg", "oga"])
        #endif
        #if canImport(COpus)
        exts.insert("opus")
        #endif
        return exts
    }

    func decode(sourceURL: URL) throws -> URL {
        let ext = sourceURL.pathExtension.lowercased()
        #if canImport(COpus)
        if ext == "opus" { return try decodeOpus(sourceURL) }
        #endif
        #if canImport(CVorbis)
        if ext == "ogg" || ext == "oga" { return try decodeVorbis(sourceURL) }
        #endif
        throw AudioDecoderError.unsupported
    }

    // MARK: - Ogg Vorbis (libvorbisfile)

    #if canImport(CVorbis)
    private func decodeVorbis(_ url: URL) throws -> URL {
        var vf = OggVorbis_File()
        guard ov_fopen(url.path, &vf) == 0 else { throw AudioDecoderError.openFailed }
        defer { ov_clear(&vf) }

        guard let info = ov_info(&vf, -1) else { throw AudioDecoderError.openFailed }
        let channels = Int(info.pointee.channels)
        let sampleRate = Int(info.pointee.rate)
        guard channels > 0, sampleRate > 0 else { throw AudioDecoderError.decodeFailed }

        var pcm = Data()
        let chunk = 4096
        var buffer = [Int8](repeating: 0, count: chunk)
        var bitstream: Int32 = 0
        while true {
            // 16-bit, little-endian, signed, interleaved.
            let read = buffer.withUnsafeMutableBufferPointer { ptr in
                ov_read(&vf, ptr.baseAddress, Int32(chunk), 0, 2, 1, &bitstream)
            }
            if read < 0 { throw AudioDecoderError.decodeFailed }
            if read == 0 { break }
            buffer.withUnsafeBytes { pcm.append($0.baseAddress!.assumingMemoryBound(to: UInt8.self), count: Int(read)) }
        }
        return try WAVWriter.write(pcm16: pcm, sampleRate: sampleRate, channels: channels)
    }
    #endif

    // MARK: - Opus (libopusfile)

    #if canImport(COpus)
    private func decodeOpus(_ url: URL) throws -> URL {
        var error: Int32 = 0
        guard let file = op_open_file(url.path, &error), error == 0 else {
            throw AudioDecoderError.openFailed
        }
        defer { op_free(file) }

        let channels = Int(op_channel_count(file, -1))
        // Opus always decodes to 48 kHz PCM.
        let sampleRate = 48_000
        guard channels > 0 else { throw AudioDecoderError.decodeFailed }

        var pcm = Data()
        let frameCapacity = 5760                 // max samples/channel per op_read call
        var buffer = [Int16](repeating: 0, count: frameCapacity * channels)
        while true {
            let samples = buffer.withUnsafeMutableBufferPointer { ptr in
                op_read(file, ptr.baseAddress, Int32(ptr.count), nil)
            }
            if samples < 0 { throw AudioDecoderError.decodeFailed }
            if samples == 0 { break }
            let byteCount = Int(samples) * channels * MemoryLayout<Int16>.size
            buffer.withUnsafeBytes { pcm.append($0.baseAddress!.assumingMemoryBound(to: UInt8.self), count: byteCount) }
        }
        return try WAVWriter.write(pcm16: pcm, sampleRate: sampleRate, channels: channels)
    }
    #endif
}

#endif
