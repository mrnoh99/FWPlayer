import SwiftUI

/// The current playback queue. Tap a track to jump to it; swipe a track to add
/// it to a playlist; use Edit to reorder or remove tracks.
struct QueueView: View {
    @Environment(AudioPlayer.self) private var player

    /// The track pending an "Add to Playlist" sheet.
    @State private var trackToAdd: Track?

    var body: some View {
        Group {
            if player.queue.isEmpty {
                EmptyStateView(
                    title: "Queue is Empty",
                    systemImage: "list.bullet",
                    message: "Play a folder or a playlist to build a queue."
                )
            } else {
                list
            }
        }
        .navigationTitle("Queue")
        .toolbar {
            if !player.queue.isEmpty {
                ToolbarItem(placement: .primaryAction) { EditButton() }
            }
        }
        .sheet(item: $trackToAdd) { track in
            AddToPlaylistView(track: track)
        }
    }

    private var list: some View {
        List {
            ForEach(Array(player.queue.enumerated()), id: \.element.id) { index, track in
                Button {
                    player.playQueueIndex(index)
                } label: {
                    QueueRow(track: track,
                             position: index + 1,
                             isCurrent: index == player.currentIndex,
                             isPlaying: player.isPlaying)
                }
                .buttonStyle(.plain)
                // Swipe shows "Add to Playlist" (not remove); removal lives in Edit.
                .swipeActions(edge: .trailing) {
                    Button {
                        trackToAdd = track
                    } label: {
                        Label("Add to Playlist", systemImage: "text.badge.plus")
                    }
                    .tint(.accentColor)
                }
            }
            .onMove { player.moveQueueItems(fromOffsets: $0, toOffset: $1) }
            .onDelete { player.removeQueueItems(atOffsets: $0) }
        }
    }
}

private struct QueueRow: View {
    let track: Track
    let position: Int
    let isCurrent: Bool
    let isPlaying: Bool

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if isCurrent {
                    Image(systemName: isPlaying ? "speaker.wave.2.fill" : "pause.fill")
                        .foregroundStyle(Color.accentColor)
                } else {
                    Text("\(position)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .lineLimit(1)
                    .foregroundStyle(isCurrent ? Color.accentColor : .primary)
                if let artist = track.artist {
                    Text(artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
        }
        .contentShape(Rectangle())
    }
}
