import SwiftUI

/// Compact transport bar pinned to the bottom of the app. Tapping it opens the
/// full `PlayerView`.
struct NowPlayingBar: View {
    @EnvironmentObject private var player: AudioPlayer
    var onTap: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "music.note")
                .font(.title3)
                .frame(width: 36, height: 36)
                .background(Color.secondary.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(player.currentTrack?.title ?? "")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                if let artist = player.currentTrack?.artist {
                    Text(artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else if let sampleRate = player.currentTrack?.sampleRate {
                    Text(AudioFormatReader.formatSampleRate(sampleRate))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()

            if player.isLoading {
                ProgressView()
            } else {
                Button {
                    player.previous()
                } label: {
                    Image(systemName: "backward.fill")
                        .font(.title3)
                }
                .disabled(!player.canGoPrevious)
                Button {
                    player.togglePlayPause()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                }
                Button {
                    player.next()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.title3)
                }
                .disabled(!player.canGoNext)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}
