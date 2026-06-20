import SwiftUI

/// Playback queue and history, each shown as a collapsible section. Tap a section
/// header to open/close it. The Queue header's ••• menu has Edit (reorder/remove)
/// and Clear; each row's ••• menu has Locate File, Add to Playlist, and Remove.
/// History lists recently played tracks, most recent first.
struct QueueView: View {
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var playlists: PlaylistManager
    /// Reveals a track's file in the browser (jumps to its source).
    var onLocate: ((Track) -> Void)? = nil

    @State private var queueExpanded = true
    @State private var historyExpanded = false
    @State private var editMode: EditMode = .inactive
    @State private var trackToAdd: Track?

    var body: some View {
        List {
            queueSection
            historySection
        }
        .listStyle(.plain)
        .environment(\.editMode, $editMode)
        .navigationTitle("Queue")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: player.queue.isEmpty) { _, isEmpty in
            if isEmpty { editMode = .inactive }
        }
        .sheet(item: $trackToAdd) { track in
            AddToPlaylistView(track: track)
        }
    }

    // MARK: - Queue section

    private var queueSection: some View {
        Section {
            if queueExpanded {
                if player.queue.isEmpty {
                    Text("Queue is empty")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(player.queue.enumerated()), id: \.element.id) { index, track in
                        row(track: track, index: index, isCurrent: player.currentIndex == index,
                            onPlay: { player.play(at: index) },
                            onRemove: { player.removeFromQueue(at: IndexSet(integer: index)) })
                    }
                    .onMove { offsets, destination in
                        Task { @MainActor in player.moveQueue(fromOffsets: offsets, toOffset: destination) }
                    }
                    .onDelete { offsets in
                        Task { @MainActor in player.removeFromQueue(at: offsets) }
                    }
                }
            }
        } header: {
            sectionHeader(title: "Queue", count: player.queue.count, isExpanded: $queueExpanded) {
                HStack(spacing: 16) {
                    Button {
                        queueExpanded = true
                        withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                    } label: {
                        Text(editMode.isEditing ? "Done" : "Edit")
                    }
                    .disabled(player.queue.isEmpty)

                    Button(role: .destructive) {
                        editMode = .inactive
                        player.clearQueue()
                    } label: {
                        Label("Clear", systemImage: "trash")
                    }
                    .labelStyle(.iconOnly)
                    .disabled(player.queue.isEmpty)
                }
                .buttonStyle(.borderless)
                .font(.subheadline)
            }
        }
    }

    // MARK: - History section

    private var historySection: some View {
        Section {
            if historyExpanded {
                if player.history.isEmpty {
                    Text("No history yet")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(player.history.enumerated()), id: \.element.id) { index, track in
                        row(track: track, index: index, isCurrent: false,
                            onPlay: { player.playNext(track) },
                            onRemove: { player.removeFromHistory(at: IndexSet(integer: index)) })
                    }
                }
            }
        } header: {
            sectionHeader(title: "History", count: player.history.count, isExpanded: $historyExpanded) {
                Menu {
                    Button(role: .destructive) { player.clearHistory() } label: {
                        Label("Clear History", systemImage: "trash")
                    }
                } label: { ellipsisLabel }
                .disabled(player.history.isEmpty)
            }
        }
    }

    // MARK: - Shared row

    @ViewBuilder
    private func row(track: Track, index: Int, isCurrent: Bool,
                     onPlay: @escaping () -> Void, onRemove: @escaping () -> Void) -> some View {
        // The ••• menu lives OUTSIDE the play-tap area (and the Catalyst
        // double-click overlay) so its action list always opens.
        HStack(spacing: 6) {
            playArea(track: track, index: index, isCurrent: isCurrent, onPlay: onPlay)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                playlists.toggleFavorite(track)
            } label: {
                Image(systemName: playlists.isFavorite(track) ? "star.fill" : "star")
                    .foregroundStyle(playlists.isFavorite(track) ? Color.yellow : Color.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(playlists.isFavorite(track) ? "Remove from Favorites" : "Add to Favorites")

            QueueRowMenu(
                isFavorite: playlists.isFavorite(track),
                onPlayNow: { Task { @MainActor in onPlay() } },
                onToggleFavorite: { playlists.toggleFavorite(track) },
                onAddToPlaylist: { trackToAdd = track },
                onLocate: onLocate.map { locate in { locate(track) } },
                onRemove: { Task { @MainActor in onRemove() } }
            )
        }
    }

    @ViewBuilder
    private func playArea(track: Track, index: Int, isCurrent: Bool,
                          onPlay: @escaping () -> Void) -> some View {
        PlaybackRowInteraction(
            isHighlighted: isCurrent,
            onSelect: {},
            onPlay: { Task { @MainActor in onPlay() } }
        ) {
            QueueRow(index: index, track: track, isCurrent: isCurrent, isPlaying: player.isPlaying)
        }
        #if targetEnvironment(macCatalyst)
        .overlay {
            DoubleClickDetector(onSingleClick: {}, onDoubleClick: { Task { @MainActor in onPlay() } })
        }
        #endif
    }

    // MARK: - Header

    private var ellipsisLabel: some View {
        Image(systemName: "ellipsis")
            .font(.body)
            .foregroundStyle(.secondary)
            .frame(width: 36, height: 36)
            .contentShape(Rectangle())
    }

    private func sectionHeader<MenuContent: View>(
        title: String, count: Int, isExpanded: Binding<Bool>,
        @ViewBuilder menu: () -> MenuContent
    ) -> some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.wrappedValue.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded.wrappedValue ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.bold))
                    Text(title).font(.headline)
                    if count > 0 {
                        Text("\(count)").font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            menu()
        }
        .textCase(nil)
        .padding(.vertical, 2)
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
            .frame(width: 26, alignment: .center)

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
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

/// The trailing ••• action menu for a queue row, kept separate from the row's
/// play-tap area so it reliably opens on every platform.
private struct QueueRowMenu: View {
    var isFavorite: Bool = false
    var onPlayNow: (() -> Void)? = nil
    var onToggleFavorite: (() -> Void)? = nil
    var onAddToPlaylist: (() -> Void)? = nil
    var onLocate: (() -> Void)? = nil
    var onRemove: (() -> Void)? = nil

    var body: some View {
        Menu {
            if let onPlayNow {
                Button(action: onPlayNow) { Label("Play Now", systemImage: "play.fill") }
            }
            if let onToggleFavorite {
                Button(action: onToggleFavorite) {
                    Label(isFavorite ? "Remove from Favorites" : "Add to Favorites",
                          systemImage: isFavorite ? "star.slash" : "star")
                }
            }
            if let onAddToPlaylist {
                Button(action: onAddToPlaylist) { Label("Add to Playlist", systemImage: "text.badge.plus") }
            }
            if let onLocate {
                Button(action: onLocate) { Label("Locate File", systemImage: "folder") }
            }
            if let onRemove {
                Button(role: .destructive, action: onRemove) { Label("Remove from Queue", systemImage: "trash") }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 36, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
    }
}
