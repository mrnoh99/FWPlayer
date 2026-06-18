import SwiftUI

/// Shows the contents of one playlist: play the whole list, reorder, delete
/// entries, rename, or delete the playlist.
struct PlaylistDetailView: View {
    let playlistID: UUID

    @EnvironmentObject private var playlists: PlaylistManager
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var registry: SourceRegistry

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
        .onChange(of: player.currentTrack?.id) { syncFocusFromPlayer() }
        .onChange(of: player.transportEventID) { syncFocusFromPlayer() }
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
                onPlay: { play(playlist, startAt: index) }
            ) {
                EntryRow(
                    entry: entry,
                    isCurrent: isCurrent(entry),
                    directURL: registry.source(for: entry.sourceID)?.directURL(forPath: entry.path)
                )
            }
            .id(entry.id)
            #if targetEnvironment(macCatalyst)
            .tag(entry.id)
            .overlay {
                DoubleClickDetector(
                    onSingleClick: { focus(on: entry, transient: false) },
                    onDoubleClick: { play(playlist, startAt: index) }
                )
            }
            #endif
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
    let directURL: URL?

    @EnvironmentObject private var player: AudioPlayer
    @State private var loadedSampleRate: Double?

    private var displayedSampleRate: Double? {
        if isCurrent, let rate = player.currentTrack?.sampleRate { return rate }
        return loadedSampleRate
    }

    var body: some View {
        HStack {
            Image(systemName: isCurrent ? "speaker.wave.2.fill" : "music.note")
                .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .lineLimit(1)
                if let sampleRate = displayedSampleRate {
                    Text(AudioFormatReader.formatSampleRate(sampleRate))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .task(id: directURL?.path) {
            guard let directURL else { return }
            loadedSampleRate = await AudioFormatReader.sampleRate(for: directURL)
        }
    }
}
