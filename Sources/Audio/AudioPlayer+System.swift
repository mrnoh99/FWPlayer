import Foundation
import AVFoundation
import MediaPlayer
import Combine
#if os(iOS)
import UIKit
#endif

/// The audio session, background reachability, interruptions and route changes, and the
/// lock-screen / Control Center Now Playing integration.
extension AudioPlayer {
    // MARK: - Audio session

    func configureAudioSession() {
        #if os(iOS)
        // Activating the session can block (it talks to the audio daemon, and a USB DAC may
        // have to switch mode), so it never happens on the main thread.
        AudioSessionQueue.queue.async {
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback, mode: .default)
            // Hi-res USB output is steadier with a larger I/O buffer; latency doesn't
            // matter for playback.
            try? session.setPreferredIOBufferDuration(0.1)
            try? session.setActive(true)
        }
        #endif
    }

    /// Tracks the system output volume so bit-perfect mode can warn when it isn't
    /// at maximum.
    func observeSystemVolume() {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        systemVolumeObservation = AVAudioSession.sharedInstance()
            .observe(\.outputVolume, options: [.initial, .new]) { [weak self] session, _ in
                let volume = session.outputVolume
                Self.runOnMainActor {
                    guard let self else { return }
                    self.systemVolume = volume
                    // Lowering the volume mid-DSD would blast noise: stop it.
                    if self.isPlaying, let problem = self.doPPlaybackProblem() {
                        self.pausePlayback()
                        self.errorMessage = problem
                    }
                }
            }
        #endif
    }

    // MARK: - Background reachability (screen off, paused)

    /// Watches app foreground/background transitions so the player can stay
    /// remote-controllable with the screen off. While playing, the `audio`
    /// background mode already keeps the app alive; the gap this covers is
    /// "backgrounded + paused/idle", where iOS would otherwise suspend the
    /// process and drop the remote's network link.
    func observeAppLifecycle() {
        #if os(iOS)
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                           object: nil, queue: .main) { [weak self] _ in
            Self.runOnMainActor {
                guard let self else { return }
                self.isInBackground = true
                // Re-assert the audio session so active playback keeps going
                // with the screen off, exactly like the Music app.
                if self.isPlaying {
                    AudioSessionQueue.queue.async { try? AVAudioSession.sharedInstance().setActive(true) }
                }
                self.updateBackgroundKeepAlive()
            }
        }
        center.addObserver(forName: UIApplication.willEnterForegroundNotification,
                           object: nil, queue: .main) { [weak self] _ in
            Self.runOnMainActor {
                self?.isInBackground = false
                self?.updateBackgroundKeepAlive()
            }
        }
        #endif
    }

    /// Starts the inaudible keep-alive stream only when it's needed — the app is
    /// in the background, the feature is enabled, and real audio isn't already
    /// playing (which keeps the app alive on its own) — and stops it otherwise.
    func updateBackgroundKeepAlive() {
        #if os(iOS)
        if backgroundRemoteEnabled && isInBackground && !isPlaying {
            keepAlive.start()
        } else {
            keepAlive.stop()
        }
        #endif
    }

    // MARK: - Audio session events (interruptions, route, reset)

    func observeAudioSessionEvents() {
        #if os(iOS)
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        center.addObserver(forName: AVAudioSession.interruptionNotification,
                           object: session, queue: .main) { [weak self] note in
            Self.runOnMainActor { self?.handleInterruption(note) }
        }
        center.addObserver(forName: AVAudioSession.routeChangeNotification,
                           object: session, queue: .main) { [weak self] note in
            Self.runOnMainActor { self?.handleRouteChange(note) }
        }
        center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                           object: session, queue: .main) { [weak self] _ in
            Self.runOnMainActor { self?.handleMediaServicesReset() }
        }
        #endif
    }

    #if os(iOS)
    private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            // The system has already paused our audio; mirror that in our state
            // and remember we should resume when the interruption ends.
            wasPlayingBeforeInterruption = isPlaying
            if isPlaying {
                player?.pause()
                isPlaying = false
                updateNowPlaying()
            }
        case .ended:
            let options: AVAudioSession.InterruptionOptions
            if let rawOpts = info[AVAudioSessionInterruptionOptionKey] as? UInt {
                options = AVAudioSession.InterruptionOptions(rawValue: rawOpts)
            } else {
                options = []
            }
            if options.contains(.shouldResume) && wasPlayingBeforeInterruption {
                // Re-activate off the main thread, then resume once the session is live.
                AudioSessionQueue.queue.async { [weak self] in
                    try? AVAudioSession.sharedInstance().setActive(true)
                    Task { @MainActor in self?.resumePlayback() }
                }
            }
            wasPlayingBeforeInterruption = false
        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ note: Notification) {
        // A DAC being plugged in or removed changes the hardware rate.
        refreshOutputSampleRate()
        // DSD (DoP) must never reach anything but a USB DAC.
        if isPlaying, let problem = doPPlaybackProblem() {
            pausePlayback()
            errorMessage = problem
        }
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
        // Headphones/Bluetooth device removed: pause instead of suddenly
        // blasting the built-in speaker — matches the Music app.
        if reason == .oldDeviceUnavailable, isPlaying {
            pausePlayback()
        }
    }

    private func handleMediaServicesReset() {
        // The audio server crashed and restarted; every audio object is now
        // invalid. Rebuild the session and player and resume where we were.
        let resumeIndex = currentIndex
        let wasPlaying = isPlaying
        player?.detach()
        player?.stop()
        player = nil
        configureAudioSession()
        if wasPlaying, let i = resumeIndex {
            loadAndPlay(index: i)
        }
    }
    #endif

    // MARK: - Remote commands & Now Playing

    func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Self.runOnMainActor { self?.togglePlayPause() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Self.runOnMainActor { self?.togglePlayPause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Self.runOnMainActor { self?.togglePlayPause() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Self.runOnMainActor { self?.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            var result = MPRemoteCommandHandlerStatus.commandFailed
            Self.runOnMainActor { [weak self] in
                guard let self, self.canGoPrevious else { return }
                self.previous()
                result = .success
            }
            return result
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Self.runOnMainActor { self?.seek(to: event.positionTime) }
            return .success
        }
    }

    /// Runs work on the main actor without trapping when callbacks arrive off the main thread.
    private nonisolated static func runOnMainActor(_ action: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { action() }
        } else {
            DispatchQueue.main.sync {
                MainActor.assumeIsolated { action() }
            }
        }
    }

    func updateNowPlaying() {
        guard let track = currentTrack else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]
        if let artist = track.artist { info[MPMediaItemPropertyArtist] = artist }
        if let composer = track.composer { info[MPMediaItemPropertyComposer] = composer }
        if let album = track.album { info[MPMediaItemPropertyAlbumTitle] = album }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
