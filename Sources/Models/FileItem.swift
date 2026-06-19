import Foundation

/// A single browsable entry returned by a `FileSource`, independent of whether
/// it lives on the local device or on a remote SMB share.
struct FileItem: Identifiable, Hashable, Codable {
    enum Kind: Hashable, Codable {
        case directory
        case audio
        case other
    }

    /// Source-relative path (POSIX style, using "/" separators).
    let path: String
    let name: String
    let kind: Kind
    let size: Int64?
    let modified: Date?

    var id: String { path }

    var isPlayable: Bool { kind == .audio }

    /// Lower-cased file extension, if any.
    var fileExtension: String {
        (name as NSString).pathExtension.lowercased()
    }

    /// Formats the system audio stack (`AVAudioPlayer` / Core Audio) decodes
    /// natively on iOS 17+ / macOS 14+: lossless (FLAC, WAV, AIFF, Apple Lossless,
    /// CAF, AU) and lossy (MP3, AAC / MPEG-4 audio).
    static let nativeAudioExtensions: Set<String> = [
        // Lossless / uncompressed
        "flac", "wav", "wave",
        "aif", "aiff", "aifc",
        "caf", "alac",
        "au", "snd",
        // Lossy / compressed
        "mp3",
        "m4a", "m4b",
        "aac", "adts",
    ]

    /// Every extension FWPlayer treats as playable: the native formats plus any
    /// (e.g. Ogg Vorbis / Opus) handled by a bundled third-party decoder.
    static var audioExtensions: Set<String> {
        nativeAudioExtensions.union(ExternalAudioFormats.extensions)
    }

    static func kind(forName name: String, isDirectory: Bool) -> Kind {
        if isDirectory { return .directory }
        let ext = (name as NSString).pathExtension.lowercased()
        return audioExtensions.contains(ext) ? .audio : .other
    }
}
