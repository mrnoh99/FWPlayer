import Foundation

// MARK: - FWPlayer Remote Control wire protocol
//
// This file defines the messages exchanged between an FWPlayer instance (the
// "player", which hosts a Bonjour `_fwplayer._tcp` service) and an FWPlayerRemote
// controller app. It is intentionally self-contained and IDENTICAL in both the
// FWPlayer and FWPlayerRemote projects so the two sides stay in sync. If you
// change it here, copy the same change to the other repository.

/// Bonjour service type advertised by FWPlayer and browsed for by the remote.
let fwRemoteServiceType = "_fwplayer._tcp"

/// A protocol version so the two sides can detect a mismatch.
let fwRemoteProtocolVersion = 1

/// A track as exposed to the remote. A trimmed-down, transport-friendly mirror
/// of the player's internal `Track`.
struct RemoteTrack: Codable, Hashable, Identifiable {
    var id: String
    var title: String
    var artist: String?
    var album: String?
    var duration: TimeInterval?
}

/// A full snapshot of the player's transport state, pushed to every connected
/// remote whenever anything changes.
struct PlaybackState: Codable, Hashable {
    var protocolVersion: Int = fwRemoteProtocolVersion
    var deviceName: String
    var isPlaying: Bool
    var isLoading: Bool
    var currentTime: TimeInterval
    var duration: TimeInterval
    var currentIndex: Int?
    var queue: [RemoteTrack]
    var errorMessage: String?
    /// Current output format, e.g. "96 kHz · 24-bit · Stereo".
    var audioFormat: String?
}

/// A minimal description of a track the remote wants to enqueue. Carries exactly
/// the fields the player needs to rebuild an internal `Track` and resolve it back
/// to a playable file.
struct RemoteQueueTrack: Codable, Hashable {
    var sourceID: String
    var path: String
    var title: String
}

/// A browsable file location on the player (its on-device folder, an added
/// folder, or an SMB share).
struct RemoteSource: Codable, Hashable, Identifiable {
    var id: String
    var displayName: String
    var symbolName: String
}

/// A playlist on the player, with its full ordered track list so the remote can
/// queue it directly.
struct RemotePlaylist: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var tracks: [RemoteQueueTrack]
}

/// The player's library: the sources you can browse and the playlists you can
/// queue. Sent in response to `requestLibrary`.
struct RemoteLibrary: Codable, Hashable {
    var sources: [RemoteSource]
    var playlists: [RemotePlaylist]
}

/// A single entry inside a browsed folder.
struct RemoteFileItem: Codable, Hashable, Identifiable {
    enum Kind: String, Codable { case directory, audio }
    var path: String
    var name: String
    var kind: Kind
    var size: Int64?

    var id: String { path }
}

/// The contents of one folder within a source. Sent in response to `browse`.
struct RemoteListing: Codable, Hashable {
    var sourceID: String
    var path: String
    var items: [RemoteFileItem]
    var error: String?
}

/// A command sent from the remote to the player.
enum RemoteCommand: Codable, Hashable {
    // Transport.
    case requestState
    case togglePlayPause
    case play
    case pause
    case next
    case previous
    case seek(time: TimeInterval)
    case playIndex(index: Int)
    case stop
    // Library browsing & queue construction.
    case requestLibrary
    case browse(sourceID: String, path: String)
    /// Replace the queue with `tracks` and start playing at `startAt`.
    case setQueue(tracks: [RemoteQueueTrack], startAt: Int)
    /// Append `tracks` to the end of the current queue.
    case enqueue(tracks: [RemoteQueueTrack])
}

/// The envelope exchanged over the wire. Commands flow remote → player; state,
/// library, and folder listings flow player → remote.
enum RemoteMessage: Codable {
    case command(RemoteCommand)
    case state(PlaybackState)
    case library(RemoteLibrary)
    case listing(RemoteListing)
}
