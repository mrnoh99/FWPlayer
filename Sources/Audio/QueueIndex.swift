import Foundation

/// Finding a track in the queue when the same track can be in it more than once.
///
/// A track's `id` is its source + path, so two copies of a song share an id; looking one up
/// by id alone always lands on the first copy, which is the wrong one when the second is the
/// one playing (or about to).
enum QueueIndex {
    /// The queue position of the track with `id` to use for work on the track that is playing
    /// now: the current position if it holds that track, else the first copy.
    static func ofPlaying(id: String, in ids: [String], current: Int?) -> Int? {
        if let current, ids.indices.contains(current), ids[current] == id { return current }
        return ids.firstIndex(of: id)
    }

    /// Where the track that gapless playback just moved on to sits: the position it was queued
    /// at if that still holds it, else the nearest copy after the current position, else the
    /// first copy anywhere (the queue was edited meanwhile).
    static func ofGaplessNext(id: String, queuedAt: Int, in ids: [String], current: Int?) -> Int? {
        if ids.indices.contains(queuedAt), ids[queuedAt] == id { return queuedAt }
        let after = (current ?? -1) + 1
        if after < ids.count, let found = ids[after...].firstIndex(of: id) { return found }
        return ids.firstIndex(of: id)
    }
}
