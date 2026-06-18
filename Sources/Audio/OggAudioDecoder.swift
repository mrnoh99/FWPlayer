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

/// Decodes Ogg Vorbis and Opus files to 32-bit float PCM WAV for system playback.
/// Float is the decoders' native output, so there is no quantization on the way
/// to the audio device.
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
        var bitstream: Int32 = 0
        var interleaved = [Float]()
        while true {
            // Native float output (per-channel planar); we interleave it ourselves.
            var channelPointers: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>? = nil
            let frames = ov_read_float(&vf, &channelPointers, 4096, &bitstream)
            if frames < 0 { throw AudioDecoderError.decodeFailed }
            if frames == 0 { break }
            guard let channelPointers else { continue }

            let frameCount = Int(frames)
            if interleaved.count < frameCount * channels {
                interleaved = [Float](repeating: 0, count: frameCount * channels)
            }
            for ch in 0..<channels {
                guard let samples = channelPointers[ch] else { continue }
                for f in 0..<frameCount {
                    interleaved[f * channels + ch] = samples[f]
                }
            }
            interleaved.withUnsafeBytes { raw in
                pcm.append(raw.baseAddress!.assumingMemoryBound(to: UInt8.self), count: frameCount * channels * MemoryLayout<Float>.size)
            }
        }
        return try WAVWriter.write(pcm: pcm, sampleRate: sampleRate, channels: channels, bitsPerSample: 32, isFloat: true)
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
        let frameCapacity = 5760                 // max frames/channel per op_read call
        var buffer = [Float](repeating: 0, count: frameCapacity * channels)
        while true {
            // Native float output, already interleaved.
            let frames = buffer.withUnsafeMutableBufferPointer { ptr in
                op_read_float(file, ptr.baseAddress, Int32(ptr.count), nil)
            }
            if frames < 0 { throw AudioDecoderError.decodeFailed }
            if frames == 0 { break }
            let byteCount = Int(frames) * channels * MemoryLayout<Float>.size
            buffer.withUnsafeBytes { pcm.append($0.baseAddress!.assumingMemoryBound(to: UInt8.self), count: byteCount) }
        }
        return try WAVWriter.write(pcm: pcm, sampleRate: sampleRate, channels: channels, bitsPerSample: 32, isFloat: true)
    }
    #endif
}

#endif
