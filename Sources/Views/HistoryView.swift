import SwiftUI

/// Recently played tracks, most recent first — a first-class sidebar
/// destination (mirroring the remote's History), separate from the live Queue.
/// Tapping (double-clicking on Catalyst) a row plays it immediately; the •••
/// menu offers the usual per-track actions plus Remove from History.
struct HistoryView: View {
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var playlists: PlaylistManager
    /// Reveals a track's file in the browser (jumps to its source).
    var onLocate: ((Track) -> Void)? = nil

    @State private var trackToAdd: Track?

    var body: some View {
        Group {
            if player.history.isEmpty {
                EmptyStateView(
                    title: "No History Yet",
                    systemImage: "clock.arrow.circlepath",
                    message: "Tracks you play appear here, most recent first."
                )
            } else {
                List {
                    ForEach(Array(player.history.enumerated()), id: \.element.id) { index, track in
                        row(track: track, index: index)
                    }
                    .onDelete { player.removeFromHistory(at: $0) }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("History")
        #if !targetEnvironment(macCatalyst)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(role: .destructive) { player.clearHistory() } label: {
                    Label("Clear History", systemImage: "trash")
                }
                .disabled(player.history.isEmpty)
            }
        }
        .sheet(item: $trackToAdd) { track in
            AddToPlaylistView(track: track)
        }
    }

    @ViewBuilder
    private func row(track: Track, index: Int) -> some View {
        HStack(spacing: 6) {
            playArea(track: track)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Favorite star, kept outside the play-tap area so it always works.
            Button { playlists.toggleFavorite(track) } label: {
                Image(systemName: playlists.isFavorite(track) ? "star.fill" : "star")
                    .foregroundStyle(playlists.isFavorite(track) ? Color.yellow : Color.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(playlists.isFavorite(track) ? "Remove from Favorites" : "Add to Favorites")

            menu(track: track, index: index)
        }
        .listRowBackground(isCurrent(track) ? Color.accentColor.opacity(0.18) : nil)
    }

    @ViewBuilder
    private func playArea(track: Track) -> some View {
        PlaybackRowInteraction(
            isHighlighted: isCurrent(track),
            onSelect: {},
            onPlay: { player.play(tracks: [track], startAt: 0) }
        ) {
            QueueRow(index: index(of: track), track: track,
                     isCurrent: isCurrent(track), isPlaying: player.isPlaying)
        }
        #if targetEnvironment(macCatalyst)
        .overlay {
            DoubleClickDetector(
                onSingleClick: { player.play(tracks: [track], startAt: 0) },
                onDoubleClick: { player.play(tracks: [track], startAt: 0) }
            )
        }
        #endif
    }

    private func menu(track: Track, index: Int) -> some View {
        Menu {
            Button { player.play(tracks: [track], startAt: 0) } label: {
                Label("Play Now", systemImage: "play.fill")
            }
            Button { playFromHere(at: index) } label: {
                Label("Play from Here", systemImage: "play.circle")
            }
            Button { player.playNext(track) } label: {
                Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
            }
            Button { player.enqueue(tracks: [track]) } label: {
                Label("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward")
            }
            Button { trackToAdd = track } label: {
                Label("Add to Playlist", systemImage: "text.badge.plus")
            }
            Button { playlists.toggleFavorite(track) } label: {
                Label(playlists.isFavorite(track) ? "Remove from Favorites" : "Add to Favorites",
                      systemImage: playlists.isFavorite(track) ? "star.slash" : "star")
            }
            if let onLocate {
                Button { onLocate(track) } label: { Label("Locate File", systemImage: "folder") }
            }
            Divider()
            Button(role: .destructive) {
                player.removeFromHistory(at: IndexSet(integer: index))
            } label: {
                Label("Remove from History", systemImage: "minus.circle")
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

    /// Plays this track and everything below it in the history (most recent
    /// first) as the new queue.
    private func playFromHere(at index: Int) {
        guard player.history.indices.contains(index) else { return }
        let tracks = Array(player.history[index...])
        player.play(tracks: tracks, startAt: 0)
    }

    private func isCurrent(_ track: Track) -> Bool {
        player.currentTrack?.id == track.id
    }

    /// Recency rank shown in the row's number column.
    private func index(of track: Track) -> Int {
        player.history.firstIndex(of: track) ?? 0
    }
}
