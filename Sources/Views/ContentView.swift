import SwiftUI

/// Identifies what the sidebar has selected: a file source or a playlist.
enum SidebarSelection: Hashable {
    case source(String)
    case playlist(UUID)
}

/// Root layout: a sidebar listing sources and playlists, a detail browser, and
/// a persistent Now Playing bar pinned to the bottom.
struct ContentView: View {
    @EnvironmentObject private var registry: SourceRegistry
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var playlists: PlaylistManager

    @State private var selection: SidebarSelection?
    @State private var showingFolderPicker = false
    @State private var showingAddSMB = false
    @State private var showingPlayer = false
    @State private var showingNewPlaylist = false
    @State private var newPlaylistName = ""

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .sheet(isPresented: $showingFolderPicker) {
            FolderPicker { url in
                try? registry.addLocalFolder(url: url)
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showingAddSMB) {
            AddSMBServerView()
        }
        .sheet(isPresented: $showingPlayer) {
            PlayerView()
        }
        .alert("New Playlist", isPresented: $showingNewPlaylist) {
            TextField("Playlist name", text: $newPlaylistName)
            Button("Cancel", role: .cancel) { newPlaylistName = "" }
            Button("Create") {
                let playlist = playlists.create(name: newPlaylistName)
                newPlaylistName = ""
                selection = .playlist(playlist.id)
            }
        } message: {
            Text("Give your playlist a name.")
        }
        .safeAreaInset(edge: .bottom) {
            if player.currentTrack != nil {
                NowPlayingBar { showingPlayer = true }
            }
        }
    }

    private var sidebar: some View {
        List(selection: $selection) {
            Section("Library") {
                ForEach(registry.sources, id: \.id) { source in
                    Label(source.displayName, systemImage: source.symbolName)
                        .tag(SidebarSelection.source(source.id))
                        .contextMenu {
                            if source.kind != .localDocuments {
                                Button(role: .destructive) {
                                    registry.remove(source)
                                } label: {
                                    Label("Remove", systemImage: "trash")
                                }
                            }
                        }
                }
            }

            Section("Playlists") {
                if playlists.playlists.isEmpty {
                    Text("No playlists yet")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                ForEach(playlists.playlists) { playlist in
                    PlaylistSidebarRow(playlist: playlist)
                        .tag(SidebarSelection.playlist(playlist.id))
                }
            }
        }
        .navigationTitle("FWPlayer")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        showingFolderPicker = true
                    } label: {
                        Label("Add Folder…", systemImage: "folder.badge.plus")
                    }
                    Button {
                        showingAddSMB = true
                    } label: {
                        Label("Add SMB Server…", systemImage: "network")
                    }
                    Divider()
                    Button {
                        showingNewPlaylist = true
                    } label: {
                        Label("New Playlist…", systemImage: "music.note.list")
                    }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        NavigationStack {
            switch selection {
            case .source(let id):
                if let source = registry.source(for: id) {
                    FolderBrowserView(source: source, path: "", title: source.displayName)
                } else {
                    unavailable
                }
            case .playlist(let id):
                PlaylistDetailView(playlistID: id)
            case nil:
                unavailable
            }
        }
    }

    private var unavailable: some View {
        EmptyStateView(
            title: "Select a Source",
            systemImage: "music.note.list",
            message: "Choose a folder, SMB server, or playlist to start listening."
        )
    }
}

private struct PlaylistSidebarRow: View {
    let playlist: Playlist

    @EnvironmentObject private var playlists: PlaylistManager
    @State private var isDropTarget = false

    var body: some View {
        Label {
            Text(playlist.name)
            Text("\(playlist.entries.count)")
                .foregroundStyle(.secondary)
        } icon: {
            Image(systemName: "music.note.list")
        }
        .listRowBackground(isDropTarget ? Color.accentColor.opacity(0.15) : nil)
        .dropDestination(for: Track.self) { tracks, _ in
            for track in tracks {
                playlists.add(track, to: playlist.id)
            }
            return true
        } isTargeted: { isDropTarget = $0 }
        .contextMenu {
            Button(role: .destructive) {
                playlists.delete(playlist.id)
            } label: {
                Label("Delete Playlist", systemImage: "trash")
            }
        }
    }
}
