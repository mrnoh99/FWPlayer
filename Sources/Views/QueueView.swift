import SwiftUI

/// Live playback queue: tap a row to play it, swipe or Edit to remove.
struct QueueView: View {
    @EnvironmentObject private var player: AudioPlayer
    @Environment(\.editMode) private var editMode

    var body: some View {
        Group {
            if player.queue.isEmpty {
                EmptyStateView(
                    title: "Queue is Empty",
                    systemImage: "list.bullet",
                    message: "Browse a folder or playlist to add music, or use Add to Queue while browsing."
                )
            } else {
                queueList
            }
        }
        .navigationTitle("Queue")
        #if targetEnvironment(macCatalyst)
        .navigationSubtitle(queueSubtitle)
        #endif
        .toolbar {
            if !player.queue.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    EditButton()
                }
            }
        }
    }

    private var queueSubtitle: String {
        let count = player.queue.count
        let label = count == 1 ? "1 track" : "\(count) tracks"
        if let index = player.currentIndex, player.queue.indices.contains(index) {
            return "\(label) · playing \(index + 1) of \(count)"
        }
        return label
    }

    @ViewBuilder
    private var queueList: some View {
        #if targetEnvironment(macCatalyst)
        List {
            queueRows
        }
        .listStyle(.inset)
        #else
        List {
            queueRows
        }
        #endif
    }

    @ViewBuilder
    private var queueRows: some View {
        ForEach(Array(player.queue.enumerated()), id: \.element.id) { index, track in
            PlaybackRowInteraction(
                isHighlighted: player.currentIndex == index,
                onSelect: {},
                onPlay: { Task { @MainActor in player.play(at: index) } }
            ) {
                QueueRow(
                    index: index,
                    track: track,
                    isCurrent: player.currentIndex == index,
                    isPlaying: player.isPlaying
                )
            }
            #if targetEnvironment(macCatalyst)
            .overlay {
                DoubleClickDetector(
                    onSingleClick: {},
                    onDoubleClick: { Task { @MainActor in player.play(at: index) } }
                )
            }
            #endif
        }
        .onDelete { offsets in
            Task { @MainActor in player.removeFromQueue(at: offsets) }
        }
    }
}

private struct QueueRow: View {
    let index: Int
    let track: Track
    let isCurrent: Bool
    let isPlaying: Bool

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if isCurrent {
                    Image(systemName: isPlaying ? "speaker.wave.2.fill" : "pause.fill")
                        .foregroundStyle(.tint)
                } else {
                    Text("\(index + 1)")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .frame(width: 24, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let artist = track.artist ?? track.album {
                    Text(artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .contentShape(Rectangle())
    }
}
