import Foundation

/// A single browsable entry returned by a `FileSource`, independent of whether
/// it lives on the local device or on a remote SMB share.
struct FileItem: Identifiable, Hashable {
    enum Kind: Hashable {
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

    /// File extensions FWPlayer treats as playable audio. Covers the common
    /// formats the system audio stack (`AVAudioPlayer` / Core Audio) can decode
    /// on iOS 17+ / macOS 14+: lossless (FLAC, WAV, AIFF, Apple Lossless, CAF)
    /// and lossy (MP3, AAC / MPEG-4 audio). Files whose format the system can't
    /// actually decode are skipped at playback time with an error.
    static let audioExtensions: Set<String> = [
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

    static func kind(forName name: String, isDirectory: Bool) -> Kind {
        if isDirectory { return .directory }
        let ext = (name as NSString).pathExtension.lowercased()
        return audioExtensions.contains(ext) ? .audio : .other
    }
}
