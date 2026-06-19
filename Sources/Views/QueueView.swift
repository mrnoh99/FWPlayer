import SwiftUI

/// The playback queue, shown as a collapsible "Queue" section: tap the header to
/// open/close the list, and use the ••• menu on the header for Edit (reorder /
/// remove) and Clear.
struct QueueView: View {
    @EnvironmentObject private var player: AudioPlayer
    /// Reveals a track's file in the browser (jumps to its source).
    var onLocate: ((Track) -> Void)? = nil

    @State private var isExpanded = true
    @State private var editMode: EditMode = .inactive
    @State private var trackToAdd: Track?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if isExpanded {
                if player.queue.isEmpty {
                    EmptyStateView(
                        title: "Queue is Empty",
                        systemImage: "list.bullet",
                        message: "Browse a folder or playlist to add music, or use Play Next / Add to Queue while browsing."
                    )
                } else {
                    List {
                        queueRows
                    }
                    .listStyle(.plain)
                    .environment(\.editMode, $editMode)
                }
            } else {
                Spacer(minLength: 0)
            }
        }
        .navigationTitle("Queue")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: player.queue.isEmpty) { _, isEmpty in
            if isEmpty { editMode = .inactive }
        }
        .sheet(item: $trackToAdd) { track in
            AddToPlaylistView(track: track)
        }
    }

    // MARK: - Collapsible header (the "Queue" row)

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("Queue").font(.headline)
                    if !player.queue.isEmpty {
                        Text("\(player.queue.count)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu {
                Button {
                    isExpanded = true
                    withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                } label: {
                    Label(editMode.isEditing ? "Done" : "Edit", systemImage: "arrow.up.arrow.down")
                }
                Button(role: .destructive) {
                    player.clearQueue()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .disabled(player.queue.isEmpty)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    // MARK: - Rows

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
                    isPlaying: player.isPlaying,
                    onLocate: onLocate.map { locate in { locate(track) } },
                    onAddToPlaylist: { trackToAdd = track },
                    onRemove: { Task { @MainActor in player.removeFromQueue(at: IndexSet(integer: index)) } }
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
        .onMove { offsets, destination in
            Task { @MainActor in player.moveQueue(fromOffsets: offsets, toOffset: destination) }
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
    var onLocate: (() -> Void)? = nil
    var onAddToPlaylist: (() -> Void)? = nil
    var onRemove: (() -> Void)? = nil

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

            if onLocate != nil || onAddToPlaylist != nil || onRemove != nil {
                Menu {
                    if let onLocate {
                        Button(action: onLocate) { Label("Locate File", systemImage: "folder") }
                    }
                    if let onAddToPlaylist {
                        Button(action: onAddToPlaylist) { Label("Add to Playlist", systemImage: "text.badge.plus") }
                    }
                    if let onRemove {
                        Button(role: .destructive, action: onRemove) { Label("Remove", systemImage: "trash") }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
            }
        }
        .contentShape(Rectangle())
    }
}
