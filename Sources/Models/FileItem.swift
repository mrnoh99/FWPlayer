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

    /// File extensions FWPlayer treats as playable audio.
    static let audioExtensions: Set<String> = ["flac", "wav", "wave"]

    static func kind(forName name: String, isDirectory: Bool) -> Kind {
        if isDirectory { return .directory }
        let ext = (name as NSString).pathExtension.lowercased()
        return audioExtensions.contains(ext) ? .audio : .other
    }
}
