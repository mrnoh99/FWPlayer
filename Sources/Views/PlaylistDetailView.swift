import SwiftUI

/// Shows the contents of one playlist: play the whole list, reorder, delete
/// entries, rename, or delete the playlist.
struct PlaylistDetailView: View {
    let playlistID: UUID

    @EnvironmentObject private var playlists: PlaylistManager
    @EnvironmentObject private var player: AudioPlayer

    @State private var showingRename = false
    @State private var renameText = ""

    private var playlist: Playlist? { playlists.playlist(for: playlistID) }

    var body: some View {
        Group {
            if let playlist {
                if playlist.entries.isEmpty {
                    EmptyStateView(
                        title: "Empty Playlist",
                        systemImage: "music.note.list",
                        message: "Browse a folder or SMB share and use “Add to Playlist” to add FLAC or WAV files here."
                    )
                } else {
                    content(for: playlist)
                }
            } else {
                EmptyStateView(title: "Playlist Not Found", systemImage: "exclamationmark.triangle")
            }
        }
        .navigationTitle(playlist?.name ?? "Playlist")
        .toolbar { toolbar }
        .alert("Rename Playlist", isPresented: $showingRename) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Save") { playlists.rename(playlistID, to: renameText) }
        }
    }

    private func content(for playlist: Playlist) -> some View {
        List {
            ForEach(Array(playlist.entries.enumerated()), id: \.element.id) { index, entry in
                Button {
                    play(playlist, startAt: index)
                } label: {
                    EntryRow(entry: entry, isCurrent: isCurrent(entry))
                }
                .buttonStyle(.plain)
            }
            .onDelete { playlists.removeEntries(at: $0, from: playlistID) }
            .onMove { playlists.moveEntries(from: $0, to: $1, in: playlistID) }
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
            EditButton()
        }
    }

    private func isCurrent(_ entry: PlaylistEntry) -> Bool {
        player.currentTrack?.id == entry.id
    }

    private func play(_ playlist: Playlist, startAt index: Int) {
        player.play(tracks: playlist.tracks, startAt: index)
    }
}

private struct EntryRow: View {
    let entry: PlaylistEntry
    let isCurrent: Bool

    var body: some View {
        HStack {
            Image(systemName: isCurrent ? "speaker.wave.2.fill" : "music.note")
                .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
                .frame(width: 24)
            Text(entry.title)
                .lineLimit(1)
            Spacer()
        }
        .contentShape(Rectangle())
    }
}
