import SwiftUI

/// Floating "liquid glass" now-playing bar pinned near the bottom of the app,
/// styled like Apple Music: rounded translucent card with centered transport.
/// Tapping it opens the full `PlayerView`.
struct NowPlayingBar: View {
    @EnvironmentObject private var player: AudioPlayer
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

    private var progress: Double {
        let total = max(duration.isFinite ? duration : 0, 0.1)
        guard currentTime.isFinite else { return 0 }
        return min(max(currentTime / total, 0), 1)
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "music.note")
                    .font(.title3)
                    .frame(width: 42, height: 42)
                    .background(Color.secondary.opacity(0.18))
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title.isEmpty ? "Not Playing" : title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if let artist {
                        Text(artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    } else if let sampleRate {
                        Text(AudioFormatReader.formatSampleRate(sampleRate))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)

                if let onShowQueue, !player.queue.isEmpty {
                    Button(action: onShowQueue) {
                        Image(systemName: "list.bullet").font(.body)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }

            // Centered transport, Apple Music style.
            HStack(spacing: 40) {
                Button { Task { @MainActor in player.previous() } } label: {
                    Image(systemName: "backward.fill").font(.title3)
                }
                .disabled(!canGoPrevious)

                if isLoading {
                    ProgressView().frame(width: 34, height: 34)
                } else {
                    Button { Task { @MainActor in player.togglePlayPause() } } label: {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.title)
                    }
                }

                Button { Task { @MainActor in player.next() } } label: {
                    Image(systemName: "forward.fill").font(.title3)
                }
                .disabled(!canGoNext)
            }
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity)

            // Thin progress line.
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .tint(.accentColor)
                .scaleEffect(x: 1, y: 0.6, anchor: .center)
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.22), radius: 14, x: 0, y: 5)
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .onTapGesture(perform: onTap)
        .onAppear { refreshFromPlayer() }
        .onReceive(player.objectWillChange) { _ in
            Task { @MainActor in refreshFromPlayer() }
        }
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
    }
}
