import Foundation
import AVFoundation

// MARK: - Pluggable decoders for formats Core Audio can't play natively
//
// The system audio stack (AVAudioPlayer / Core Audio) already decodes FLAC, WAV,
// AIFF, ALAC, CAF, AU, MP3 and AAC/M4A. Formats outside its reach — notably the
// Ogg family (Ogg Vorbis and Opus) — are handled here by decoding to a temporary
// PCM (WAV) file that the system can then play through the normal pipeline. This
// preserves seeking, duration, gapless queueing and Now Playing.
//
// Quality first: decoding is done in 32-bit float (the decoders' native output)
// and written as IEEE-float WAV, so there is no intermediate 16-bit quantization.
//
// External decoders are integrated exactly like the SMB client: the code is
// compiled in only when the underlying C library modules are present
// (`#if canImport(...)`), so the app still builds — with these formats reported
// as unavailable — when the libraries aren't linked. See README for how to add
// the Xiph libraries (libvorbisfile / libopusfile) via SwiftPM.

/// A source file prepared for playback: a URL `AVAudioPlayer` can open, plus an
/// optional temporary file we own and must delete when done.
struct PlayableAudio {
    let url: URL
    /// Non-nil when `url` is a decoder-produced temp file owned by us.
    let temporaryURL: URL?

    func cleanup() {
        if let temporaryURL { try? FileManager.default.removeItem(at: temporaryURL) }
    }
}

/// Decodes a non-natively-supported audio file into a PCM file the system can play.
protocol AudioDecoder: Sendable {
    /// Lower-cased file extensions this decoder handles.
    static var supportedExtensions: Set<String> { get }
    /// Decodes `sourceURL` to a temporary WAV file and returns its URL.
    func decode(sourceURL: URL) throws -> URL
}

enum AudioDecoderError: LocalizedError {
    case openFailed
    case decodeFailed
    case unsupported

    var errorDescription: String? {
        switch self {
        case .openFailed: return "Couldn't open the audio file for decoding."
        case .decodeFailed: return "Couldn't decode the audio file."
        case .unsupported: return "No decoder is available for this format."
        }
    }
}

/// Selects the right decoder for a file and prepares files for playback.
final class AudioDecoderRegistry: Sendable {
    static let shared = AudioDecoderRegistry()

    private let decoders: [any AudioDecoder]

    init() {
        var list: [any AudioDecoder] = []
        #if canImport(COpus) || canImport(CVorbis)
        list.append(OggAudioDecoder())
        #endif
        decoders = list
    }

    /// Extensions that are playable only because an external decoder is compiled in.
    var externalExtensions: Set<String> {
        decoders.reduce(into: Set<String>()) { $0.formUnion(type(of: $1).supportedExtensions) }
    }

    private func decoder(for ext: String) -> (any AudioDecoder)? {
        decoders.first { type(of: $0).supportedExtensions.contains(ext) }
    }

    /// Returns a `PlayableAudio` for `sourceURL`. Natively supported formats pass
    /// straight through; others are decoded to a temporary WAV off the main thread.
    func prepare(sourceURL: URL, fileExtension ext: String) async throws -> PlayableAudio {
        guard let decoder = decoder(for: ext) else {
            return PlayableAudio(url: sourceURL, temporaryURL: nil)
        }
        let decoded = try await Task.detached(priority: .userInitiated) {
            try decoder.decode(sourceURL: sourceURL)
        }.value
        return PlayableAudio(url: decoded, temporaryURL: decoded)
    }
}

/// Extensions playable only through a bundled third-party decoder (empty unless
/// the relevant C library modules are linked). Used by `FileItem` so the browser
/// only marks these files playable when they actually are.
enum ExternalAudioFormats {
    static let extensions: Set<String> = {
        #if canImport(COpus) || canImport(CVorbis)
        return OggAudioDecoder.supportedExtensions
        #else
        return []
        #endif
    }()
}

// MARK: - Canonical WAV writer (32-bit float or integer PCM)

enum WAVWriter {
    /// Writes interleaved little-endian PCM to a temporary WAV file. `isFloat`
    /// selects IEEE-float (`WAVE_FORMAT_IEEE_FLOAT`, with the required `fact`
    /// chunk) vs. integer PCM. The decoders use 32-bit float to avoid any
    /// quantization step.
    static func write(pcm: Data, sampleRate: Int, channels: Int, bitsPerSample: Int, isFloat: Bool) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fwdecode-\(UUID().uuidString).wav")

        let bytesPerSample = bitsPerSample / 8
        let blockAlign = channels * bytesPerSample
        let byteRate = sampleRate * blockAlign
        let dataSize = pcm.count
        let frames = blockAlign > 0 ? dataSize / blockAlign : 0
        let formatTag: UInt16 = isFloat ? 3 : 1          // 3 = IEEE float, 1 = PCM
        let fmtChunkSize = isFloat ? 18 : 16             // non-PCM needs cbSize

        var header = Data()
        func ascii(_ s: String) { header.append(contentsOf: Array(s.utf8)) }
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { header.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { header.append(contentsOf: $0) } }

        var riffSize = 4 + (8 + fmtChunkSize) + (8 + dataSize)
        if isFloat { riffSize += 12 }                    // fact chunk (8 header + 4 data)

        ascii("RIFF"); u32(UInt32(riffSize)); ascii("WAVE")
        ascii("fmt "); u32(UInt32(fmtChunkSize))
        u16(formatTag); u16(UInt16(channels)); u32(UInt32(sampleRate)); u32(UInt32(byteRate))
        u16(UInt16(blockAlign)); u16(UInt16(bitsPerSample))
        if isFloat {
            u16(0)                                       // cbSize
            ascii("fact"); u32(4); u32(UInt32(frames))
        }
        ascii("data"); u32(UInt32(dataSize))

        var file = header
        file.append(pcm)
        try file.write(to: url)
        return url
    }
}
