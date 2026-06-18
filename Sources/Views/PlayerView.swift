import SwiftUI

/// Full-screen player with artwork placeholder, scrubber, and transport controls.
struct PlayerView: View {
    @EnvironmentObject private var player: AudioPlayer
    @Environment(\.dismiss) private var dismiss

    /// Local scrub position while the user is dragging the slider.
    @State private var scrubTime: Double = 0
    @State private var isScrubbing = false

    var body: some View {
        VStack(spacing: 28) {
            Capsule()
                .fill(Color.secondary.opacity(0.4))
                .frame(width: 40, height: 5)
                .padding(.top, 8)

            Spacer()

            Image(systemName: "music.note")
                .font(.system(size: 90))
                .foregroundStyle(.secondary)
                .frame(width: 240, height: 240)
                .background(Color.secondary.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 20))

            VStack(spacing: 6) {
                if player.isLoading {
                    ProgressView()
                } else {
                    Text(player.currentTrack?.title ?? "Not Playing")
                        .font(.title2.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
                if let artist = player.currentTrack?.artist {
                    Text(artist).foregroundStyle(.secondary)
                }
                if let album = player.currentTrack?.album {
                    Text(album).font(.subheadline).foregroundStyle(.secondary)
                }
                if let sampleRate = player.currentTrack?.sampleRate {
                    Text(AudioFormatReader.formatSampleRate(sampleRate))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal)

            scrubber

            transportControls

            Spacer()
        }
        .padding()
        .presentationDragIndicator(.hidden)
    }

    private var scrubberMax: Double {
        max(player.duration.isFinite ? player.duration : 0, 0.1)
    }

    private var displayedTime: Double {
        let time = isScrubbing ? scrubTime : player.currentTime
        guard time.isFinite else { return 0 }
        return min(max(time, 0), scrubberMax)
    }

    private var scrubber: some View {
        VStack(spacing: 4) {
            Slider(
                value: Binding(
                    get: { displayedTime },
                    set: { scrubTime = $0 }
                ),
                in: 0...scrubberMax,
                onEditingChanged: { editing in
                    isScrubbing = editing
                    if !editing { player.seek(to: scrubTime) }
                }
            )
            HStack {
                Text(timeString(displayedTime))
                Spacer()
                Text(timeString(player.duration))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
    }

    private var transportControls: some View {
        HStack(spacing: 48) {
            Button { player.previous() } label: {
                Image(systemName: "backward.fill").font(.title)
            }
            .disabled(!player.canGoPrevious)
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 64))
            }
            Button { player.next() } label: {
                Image(systemName: "forward.fill").font(.title)
            }
            .disabled(!player.canGoNext)
        }
        .buttonStyle(.plain)
    }

    private func timeString(_ time: TimeInterval) -> String {
        guard time.isFinite, time >= 0 else { return "0:00" }
        let total = Int(time)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
