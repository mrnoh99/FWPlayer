import SwiftUI

/// Full-screen player with album artwork, scrubber, and transport controls.
struct PlayerView: View {
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var artwork: ArtworkStore
    @Environment(\.dismiss) private var dismiss
    var onShowQueue: (() -> Void)? = nil

    @State private var isLoading = false
    @State private var title = "Not Playing"
    @State private var artist: String?
    @State private var album: String?
    @State private var sampleRate: Double?
    @State private var isPlaying = false
    @State private var currentTime: TimeInterval = 0
    @State private var duration: TimeInterval = 0
    @State private var canGoPrevious = false
    @State private var canGoNext = false
    @State private var isShuffled = false
    @State private var repeatMode: RepeatMode = .off

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

            Group {
                if let cover = player.currentTrack.flatMap({ artwork.image(for: $0) }) {
                    Image(uiImage: cover).resizable().scaledToFill()
                } else {
                    Image(systemName: "music.note")
                        .font(.system(size: 90))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.secondary.opacity(0.12))
                }
            }
            .frame(width: 240, height: 240)
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .shadow(color: .black.opacity(0.2), radius: 12, y: 6)

            VStack(spacing: 6) {
                if isLoading {
                    ProgressView()
                } else {
                    Text(title)
                        .font(.title2.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
                if let artist {
                    Text(artist).foregroundStyle(.secondary)
                }
                if let album {
                    Text(album).font(.subheadline).foregroundStyle(.secondary)
                }
                if let sampleRate {
                    Text(AudioFormatReader.formatSampleRate(sampleRate))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal)

            Spacer()

            scrubber

            transportControls

            shuffleRepeatControls

            Spacer(minLength: 0)
        }
        .padding()
        .presentationDragIndicator(.hidden)
        .toolbar {
            if let onShowQueue, !player.queue.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        dismiss()
                        onShowQueue()
                    } label: {
                        Label("Queue", systemImage: "list.bullet")
                    }
                }
            }
        }
        .onAppear { refreshFromPlayer() }
        .onReceive(player.objectWillChange) { _ in
            Task { @MainActor in refreshFromPlayer() }
        }
    }

    private var scrubberMax: Double {
        max(duration.isFinite ? duration : 0, 0.1)
    }

    private var displayedTime: Double {
        let time = isScrubbing ? scrubTime : currentTime
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
                    if !editing {
                        Task { @MainActor in
                            player.seek(to: scrubTime)
                        }
                    }
                }
            )
            HStack {
                Text(timeString(displayedTime))
                Spacer()
                Text(timeString(duration))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
    }

    private var transportControls: some View {
        HStack(spacing: 48) {
            Button {
                Task { @MainActor in player.previous() }
            } label: {
                Image(systemName: "backward.fill").font(.title)
            }
            .disabled(!canGoPrevious)
            Button {
                Task { @MainActor in player.togglePlayPause() }
            } label: {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 64))
            }
            Button {
                Task { @MainActor in player.next() }
            } label: {
                Image(systemName: "forward.fill").font(.title)
            }
            .disabled(!canGoNext)
        }
        .buttonStyle(.plain)
    }

    /// Apple Music–style shuffle (left) and repeat (right) row.
    private var shuffleRepeatControls: some View {
        HStack {
            Button {
                Task { @MainActor in player.toggleShuffle() }
            } label: {
                Image(systemName: "shuffle")
                    .font(.title3)
                    .foregroundStyle(isShuffled ? Color.accentColor : .secondary)
            }
            Spacer()
            Button {
                Task { @MainActor in player.cycleRepeatMode() }
            } label: {
                Image(systemName: repeatMode == .one ? "repeat.1" : "repeat")
                    .font(.title3)
                    .foregroundStyle(repeatMode == .off ? .secondary : Color.accentColor)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 44)
    }

    private func refreshFromPlayer() {
        isLoading = player.isLoading
        title = player.currentTrack?.title ?? "Not Playing"
        artist = player.currentTrack?.artist
        album = player.currentTrack?.album
        sampleRate = player.currentTrack?.sampleRate
        isPlaying = player.isPlaying
        currentTime = player.currentTime
        duration = player.duration
        canGoPrevious = player.canGoPrevious
        canGoNext = player.canGoNext
        isShuffled = player.isShuffled
        repeatMode = player.repeatMode
    }

    private func timeString(_ time: TimeInterval) -> String {
        guard time.isFinite, time >= 0 else { return "0:00" }
        let total = Int(time)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
