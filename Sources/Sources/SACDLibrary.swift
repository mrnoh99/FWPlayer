import Foundation

/// Presents an SACD image's tracks as browsable entries.
enum SACDLibrary {
    /// One `FileItem` per stereo track, at `<image path>/NN Title.sacdtrack`.
    static func trackItems(disc: SACDDisc, imagePath: String) -> [FileItem] {
        guard let area = disc.stereo else { return [] }
        return area.tracks.map { track in
            let name = SACDVirtualPath.trackName(number: track.number, title: track.title)
            return FileItem(path: imagePath + "/" + name, name: name, kind: .audio, size: nil, modified: nil)
        }
    }
}
