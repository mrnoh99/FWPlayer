import SwiftUI

/// Floating "liquid glass" now-playing bar pinned near the bottom of the app,
/// styled like the Apple Music desktop player: a single horizontal capsule with
/// the transport (shuffle · prev · play · next · repeat) on the left, the track
/// card (artwork, title/artist, favorite, thin progress) in the centre, and a
/// queue button on the right. Tapping the centre opens the full `PlayerView`.
struct NowPlayingBar: View {
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var artwork: ArtworkStore
    @EnvironmentObject private var playlists: PlaylistManager
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    var onTap: () -> Void
    var onShowQueue: (() -> Void)? = nil

    @State private var title = ""
    @State private var artist: String?
    @State private var sampleRate: Double?
    @State private var isLoading = false
    @State private var isPlaying = false
    @State private var canGoPrevious = false
    @State private var canGoNext = false
    @State private var currentTime: TimeInterval = 0
    @State private var duration: TimeInterval = 0
    @State private var isShuffled = false
    @State private var repeatMode: RepeatMode = .off
    /// Drives the "Add to Playlist" sheet from the ••• menu.
    @State private var trackToAdd: Track?

    /// Wide layouts (iPad/Mac) show the full Apple Music bar; compact (iPhone)
    /// trims the secondary controls so the essentials still fit.
    private var isWide: Bool { horizontalSizeClass == .regular }

    private var progress: Double {
        let total = max(duration.isFinite ? duration : 0, 0.1)
        guard currentTime.isFinite else { return 0 }
        return min(max(currentTime / total, 0), 1)
    }

    var body: some View {
        HStack(spacing: isWide ? 22 : 14) {
            transport
            trackCard
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .onTapGesture(perform: onTap)
            if isWide, let onShowQueue, !player.queue.isEmpty {
                Button(action: onShowQueue) {
                    Image(systemName: "list.bullet").font(.body)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            // ••• actions for the current track.
            Menu {
                Button {
                    if let track = player.currentTrack { trackToAdd = track }
                } label: {
                    Label("Add to Playlist", systemImage: "text.badge.plus")
                }
                if let track = player.currentTrack {
                    Button {
                        playlists.toggleFavorite(track)
                    } label: {
                        Label(playlists.isFavorite(track) ? "Remove from Favorites" : "Add to Favorites",
                              systemImage: playlists.isFavorite(track) ? "star.slash" : "star")
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(player.currentTrack == nil)
        }
        .padding(.horizontal, isWide ? 22 : 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.22), radius: 14, x: 0, y: 5)
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
        .onAppear { refreshFromPlayer() }
        .onReceive(player.objectWillChange) { _ in
            Task { @MainActor in refreshFromPlayer() }
        }
        .sheet(item: $trackToAdd) { track in
            AddToPlaylistView(track: track)
        }
    }

    // MARK: - Transport (left cluster)

    private var transport: some View {
        HStack(spacing: isWide ? 20 : 16) {
            if isWide {
                Button { Task { @MainActor in player.toggleShuffle() } } label: {
                    Image(systemName: "shuffle")
                        .font(.subheadline)
                        .foregroundStyle(isShuffled ? Color.accentColor : .secondary)
                }
            }
            Button { Task { @MainActor in player.previous() } } label: {
                Image(systemName: "backward.fill").font(.title3)
            }
            .disabled(!canGoPrevious)

            if isLoading {
                ProgressView().frame(width: 30, height: 30)
            } else {
                Button { Task { @MainActor in player.togglePlayPause() } } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill").font(.title)
                }
            }

            Button { Task { @MainActor in player.next() } } label: {
                Image(systemName: "forward.fill").font(.title3)
            }
            .disabled(!canGoNext)

            if isWide {
                Button { Task { @MainActor in player.cycleRepeatMode() } } label: {
                    Image(systemName: repeatMode == .one ? "repeat.1" : "repeat")
                        .font(.subheadline)
                        .foregroundStyle(repeatMode == .off ? Color.secondary : Color.accentColor)
                }
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }

    // MARK: - Track card (centre)

    private var trackCard: some View {
        VStack(spacing: 5) {
            HStack(spacing: 10) {
                cover
                    .frame(width: 38, height: 38)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

                VStack(alignment: .leading, spacing: 1) {
                    Text(title.isEmpty ? "Not Playing" : title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)

                if let track = player.currentTrack {
                    Button { playlists.toggleFavorite(track) } label: {
                        Image(systemName: playlists.isFavorite(track) ? "star.fill" : "star")
                            .font(.footnote)
                            .foregroundStyle(playlists.isFavorite(track) ? Color.yellow : .secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(playlists.isFavorite(track) ? "Remove from Favorites" : "Add to Favorites")
                }
            }

            // Thin progress line under the card, Apple Music style.
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.25))
                    Capsule().fill(Color.primary.opacity(0.55))
                        .frame(width: max(0, geo.size.width * progress))
                }
            }
            .frame(height: 3)
        }
    }

    @ViewBuilder
    private var cover: some View {
        if let image = player.currentTrack.flatMap({ artwork.image(for: $0) }) {
            Image(uiImage: image).resizable().scaledToFill()
        } else {
            Image(systemName: "music.note")
                .font(.headline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.secondary.opacity(0.18))
        }
    }

    /// Artist and the sampling rate (the rate is always shown — it matters for a
    /// bit-perfect/lossless player).
    private var subtitle: String? {
        var parts: [String] = []
        if let artist { parts.append(artist) }
        if let sampleRate { parts.append(AudioFormatReader.formatSampleRate(sampleRate)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func refreshFromPlayer() {
        title = player.currentTrack?.title ?? ""
        artist = player.currentTrack?.artist
        sampleRate = player.currentTrack?.sampleRate
        isLoading = player.isLoading
        isPlaying = player.isPlaying
        canGoPrevious = player.canGoPrevious
        canGoNext = player.canGoNext
        currentTime = player.currentTime
        duration = player.duration
        isShuffled = player.isShuffled
        repeatMode = player.repeatMode
    }
}
