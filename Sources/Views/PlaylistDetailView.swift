import SwiftUI

/// Shows the contents of one playlist: play the whole list, reorder, delete
/// entries, rename, or delete the playlist.
struct PlaylistDetailView: View {
    let playlistID: UUID
    /// Reveals a track's file in the browser (jumps to its source).
    var onLocate: ((Track) -> Void)? = nil

    @EnvironmentObject private var playlists: PlaylistManager
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var registry: SourceRegistry

    @State private var trackToAdd: Track?
    @State private var showingRename = false
    @State private var renameText = ""
    @State private var isDropTarget = false
    @State private var selectedEntryID: String?
    @State private var scrollTarget: String?
    @State private var editMode: EditMode = .inactive
    @State private var focusRevertTask: Task<Void, Never>?

    private var playlist: Playlist? { playlists.playlist(for: playlistID) }

    var body: some View {
        Group {
            if let playlist {
                if playlist.entries.isEmpty {
                    EmptyStateView(
                        title: "Empty Playlist",
                        systemImage: "music.note.list",
                        message: "Drag FLAC or WAV files here from a folder, or use “Add to Playlist” while browsing."
                    )
                } else {
                    content(for: playlist)
                }
            } else {
                EmptyStateView(title: "Playlist Not Found", systemImage: "exclamationmark.triangle")
            }
        }
        .background(isDropTarget ? Color.accentColor.opacity(0.08) : Color.clear)
        .dropDestination(for: Track.self) { tracks, _ in
            addDroppedTracks(tracks)
            return true
        } isTargeted: { isDropTarget = $0 }
        .navigationTitle(playlist?.name ?? "Playlist")
        .environment(\.editMode, $editMode)
        .toolbar { toolbar }
        .onChange(of: player.currentTrack?.id) {
            Task { @MainActor in syncFocusFromPlayer() }
        }
        .onChange(of: player.transportEventID) {
            Task { @MainActor in syncFocusFromPlayer() }
        }
        .onChange(of: selectedEntryID) { _, new in
            guard let new else { return }
            scrollTarget = new
            if new == currentPlayingEntryID {
                ListFocusBehavior.cancelRevert(task: &focusRevertTask)
            } else {
                scheduleFocusRevert()
            }
        }
        .alert("Rename Playlist", isPresented: $showingRename) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Save") { playlists.rename(playlistID, to: renameText) }
        }
        .sheet(item: $trackToAdd) { track in
            AddToPlaylistView(track: track)
        }
    }

    private func content(for playlist: Playlist) -> some View {
        Group {
            #if targetEnvironment(macCatalyst)
            List(selection: $selectedEntryID) {
                playlistRows(for: playlist)
            }
            .listStyle(.inset)
            #else
            List {
                playlistRows(for: playlist)
            }
            #endif
        }
        .scrollPosition(id: $scrollTarget, anchor: .center)
    }

    @ViewBuilder
    private func playlistRows(for playlist: Playlist) -> some View {
        ForEach(Array(playlist.entries.enumerated()), id: \.element.id) { index, entry in
            PlaybackRowInteraction(
                isHighlighted: isFocused(entry),
                onSelect: { focus(on: entry, transient: false) },
                onPlay: { player.playNext(Track(entry: entry)) }
            ) {
                EntryRow(
                    entry: entry,
                    isCurrent: isCurrent(entry),
                    isPlaying: player.isPlaying,
                    directURL: registry.source(for: entry.sourceID)?.directURL(forPath: entry.path),
                    onPlayNow: { player.play(tracks: [Track(entry: entry)], startAt: 0) },
                    onPlayFromHere: { play(playlist, startAt: index) },
                    onPlayNext: { player.playNext(Track(entry: entry)) },
                    onAddToQueue: { player.enqueue(tracks: [Track(entry: entry)]) },
                    onAddToPlaylist: { trackToAdd = Track(entry: entry) },
                    onMoveUp: index > 0
                        ? { playlists.moveEntries(from: IndexSet(integer: index), to: index - 1, in: playlistID) }
                        : nil,
                    onMoveDown: index < playlist.entries.count - 1
                        ? { playlists.moveEntries(from: IndexSet(integer: index), to: index + 2, in: playlistID) }
                        : nil,
                    onLocate: onLocate.map { locate in { locate(Track(entry: entry)) } }
                )
            }
            .id(entry.id)
            #if targetEnvironment(macCatalyst)
            .tag(entry.id)
            .overlay {
                DoubleClickDetector(
                    onSingleClick: { play(playlist, startAt: index) },
                    onDoubleClick: { play(playlist, startAt: index) },
                    leadingPassthrough: 34,
                    trailingPassthrough: 48
                )
            }
            .contextMenu {
                Button {
                    player.enqueue(tracks: [Track(sourceID: entry.sourceID, path: entry.path, title: entry.title)])
                } label: {
                    Label("Add to Queue", systemImage: "text.line.first.and.arrowtriangle.forward")
                }
            }
            #endif
            .swipeActions(edge: .trailing) {
                Button {
                    player.enqueue(tracks: [Track(sourceID: entry.sourceID, path: entry.path, title: entry.title)])
                } label: {
                    Label("Queue", systemImage: "text.line.first.and.arrowtriangle.forward")
                }
                .tint(.blue)
            }
        }
        .onDelete { playlists.removeEntries(at: $0, from: playlistID) }
        .onMove { playlists.moveEntries(from: $0, to: $1, in: playlistID) }
    }

    private func syncFocusFromPlayer() {
        ListFocusBehavior.cancelRevert(task: &focusRevertTask)
        guard player.activePlaylistID == playlistID,
              let current = player.currentTrack else { return }
        selectedEntryID = current.id
        scrollTarget = current.id
    }

    private var currentPlayingEntryID: String? {
        guard player.activePlaylistID == playlistID else { return nil }
        return player.currentTrack?.id
    }

    private func isFocused(_ entry: PlaylistEntry) -> Bool {
        selectedEntryID == entry.id
    }

    private func focus(on entry: PlaylistEntry, transient: Bool = true) {
        selectedEntryID = entry.id
        scrollTarget = entry.id
        if transient {
            scheduleFocusRevert()
        }
    }

    private func scheduleFocusRevert() {
        ListFocusBehavior.scheduleRevert(
            task: &focusRevertTask,
            to: currentPlayingEntryID,
            isPlaybackActive: player.currentTrack != nil && player.activePlaylistID == playlistID,
            currentFocusID: selectedEntryID
        ) { playingID in
            selectedEntryID = playingID
            scrollTarget = playingID
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if let playlist, !playlist.entries.isEmpty {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    play(playlist, startAt: 0)   // replace the queue with the whole playlist
                } label: {
                    Image(systemName: "play.circle.fill")
                }
                .accessibilityLabel("Play Playlist")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                if let playlist, !playlist.entries.isEmpty {
                    Button {
                        play(playlist, startAt: 0)
                    } label: {
                        Label("Play", systemImage: "play.fill")
                    }
                }
                Button {
                    renameText = playlist?.name ?? ""
                    showingRename = true
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    playlists.delete(playlistID)
                } label: {
                    Label("Delete Playlist", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button(editMode.isEditing ? "Done" : "Edit") {
                withAnimation {
                    editMode = editMode.isEditing ? .inactive : .active
                }
            }
        }
    }

    private func isCurrent(_ entry: PlaylistEntry) -> Bool {
        player.currentTrack?.id == entry.id
    }

    private func play(_ playlist: Playlist, startAt index: Int) {
        guard playlist.entries.indices.contains(index) else { return }
        ListFocusBehavior.cancelRevert(task: &focusRevertTask)
        focus(on: playlist.entries[index], transient: false)
        player.play(tracks: playlist.tracks, startAt: index, fromPlaylist: playlist.id)
    }

    private func addDroppedTracks(_ tracks: [Track]) {
        for track in tracks {
            playlists.add(track, to: playlistID)
        }
    }
}

private struct EntryRow: View {
    let entry: PlaylistEntry
    let isCurrent: Bool
    var isPlaying: Bool = false
    let directURL: URL?
    var onPlayNow: (() -> Void)? = nil
    var onPlayFromHere: (() -> Void)? = nil
    var onPlayNext: (() -> Void)? = nil
    var onAddToQueue: (() -> Void)? = nil
    var onAddToPlaylist: (() -> Void)? = nil
    var onMoveUp: (() -> Void)? = nil
    var onMoveDown: (() -> Void)? = nil
    var onLocate: (() -> Void)? = nil

    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var playlists: PlaylistManager
    @State private var loadedSampleRate: Double?
    @State private var duration: Double?

    private var track: Track { Track(entry: entry) }

    private var displayedSampleRate: Double? {
        if isCurrent, let rate = player.currentTrack?.sampleRate { return rate }
        return loadedSampleRate
    }

    private var subtitle: String? {
        guard let rate = displayedSampleRate else { return nil }
        return AudioFormatReader.formatSampleRate(rate)
    }

    private var timeText: String {
        if let duration { return AudioFormatReader.formatDuration(duration) }
        return ""
    }

    var body: some View {
        HStack(spacing: 8) {
            // Favorite star in a leading gutter, outside the row highlight.
            Button { playlists.toggleFavorite(track) } label: {
                Image(systemName: playlists.isFavorite(track) ? "star.fill" : "star")
                    .font(.footnote)
                    .foregroundStyle(playlists.isFavorite(track) ? Color.yellow : Color.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(playlists.isFavorite(track) ? "Remove from Favorites" : "Add to Favorites")

            HStack(spacing: 10) {
                ArtworkThumbnail(track: track, directURL: directURL, isCurrent: isCurrent)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        if isCurrent {
                            Image(systemName: isPlaying ? "speaker.wave.2.fill" : "pause.fill")
                                .font(.caption)
                                .foregroundStyle(.tint)
                        }
                        Text(entry.title)
                            .fontWeight(isCurrent ? .semibold : .regular)
                            .lineLimit(1)
                    }
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                if !timeText.isEmpty {
                    Text(timeText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Menu {
                    if let onPlayNow {
                        Button(action: onPlayNow) { Label("Play Now", systemImage: "play.fill") }
                    }
                    if let onPlayFromHere {
                        Button(action: onPlayFromHere) { Label("Play from Here", systemImage: "play.circle") }
                    }
                    if let onPlayNext {
                        Button(action: onPlayNext) { Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") }
                    }
                    if let onAddToQueue {
                        Button(action: onAddToQueue) { Label("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward") }
                    }
                    if let onAddToPlaylist {
                        Button(action: onAddToPlaylist) { Label("Add to Playlist", systemImage: "text.badge.plus") }
                    }
                    if onMoveUp != nil || onMoveDown != nil {
                        Section {
                            Button(action: onMoveUp ?? {}) { Label("Move Up", systemImage: "arrow.up") }
                                .disabled(onMoveUp == nil)
                            Button(action: onMoveDown ?? {}) { Label("Move Down", systemImage: "arrow.down") }
                                .disabled(onMoveDown == nil)
                        }
                    }
                    Button {
                        playlists.toggleFavorite(track)
                    } label: {
                        Label(playlists.isFavorite(track) ? "Remove from Favorites" : "Add to Favorites",
                              systemImage: playlists.isFavorite(track) ? "star.slash" : "star")
                    }
                    if let onLocate {
                        Button(action: onLocate) { Label("Locate File", systemImage: "folder") }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 10)
            .background(isCurrent ? Color.accentColor.opacity(0.15) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .contentShape(Rectangle())
        .task(id: directURL?.path) {
            guard let directURL else { return }
            loadedSampleRate = await AudioFormatReader.sampleRate(for: directURL)
            duration = await AudioFormatReader.duration(for: directURL)
        }
    }
}
