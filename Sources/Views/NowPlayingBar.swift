import SwiftUI

/// Compact transport bar pinned to the bottom of the app. Tapping it opens the
/// full `PlayerView`.
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
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: "music.note")
                    .font(.title2)
                    .frame(width: 44, height: 44)
                    .background(Color.secondary.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    if let artist {
                        Text(artist)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else if let sampleRate {
                        Text(AudioFormatReader.formatSampleRate(sampleRate))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()

                if let onShowQueue, !player.queue.isEmpty {
                    Button(action: onShowQueue) {
                        Image(systemName: "list.bullet")
                            .font(.title3)
                    }
                    .buttonStyle(.plain)
                }

                if isLoading {
                    ProgressView()
                } else {
                    Button {
                        Task { @MainActor in player.previous() }
                    } label: {
                        Image(systemName: "backward.fill")
                            .font(.title3)
                    }
                    .disabled(!canGoPrevious)
                    Button {
                        Task { @MainActor in player.togglePlayPause() }
                    } label: {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.title2)
                    }
                    Button {
                        Task { @MainActor in player.next() }
                    } label: {
                        Image(systemName: "forward.fill")
                            .font(.title3)
                    }
                    .disabled(!canGoNext)
                }
            }

            VStack(spacing: 4) {
                HStack {
                    Text(Self.timeString(currentTime))
                    Spacer()
                    Text(Self.timeString(duration))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
        .contentShape(Rectangle())
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

    private static func timeString(_ time: TimeInterval) -> String {
        guard time.isFinite, time >= 0 else { return "0:00" }
        let total = Int(time)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
