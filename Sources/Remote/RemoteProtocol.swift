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
}

/// A transport command sent from the remote to the player.
enum RemoteCommand: Codable, Hashable {
    case requestState
    case togglePlayPause
    case play
    case pause
    case next
    case previous
    case seek(time: TimeInterval)
    case playIndex(index: Int)
    case stop
}

/// The envelope exchanged over the wire. Commands flow remote → player; state
/// flows player → remote.
enum RemoteMessage: Codable {
    case command(RemoteCommand)
    case state(PlaybackState)
}
