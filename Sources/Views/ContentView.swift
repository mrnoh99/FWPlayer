import SwiftUI

/// Identifies what the sidebar has selected: a file source or a playlist.
enum SidebarSelection: Hashable {
    case source(String)
    case playlist(UUID)
    case queue
    case history
}

/// Root layout: a sidebar listing sources and playlists, a detail browser, and
/// a persistent Now Playing bar pinned to the bottom.
struct ContentView: View {
    @EnvironmentObject private var registry: SourceRegistry
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var playlists: PlaylistManager
    @EnvironmentObject private var artwork: ArtworkStore
    @EnvironmentObject private var remoteServer: RemoteControlServer
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var selection: SidebarSelection?
    @State private var showingFolderPicker = false
    @State private var showingAddSMB = false
    @State private var showingPlayer = false
    @State private var showingNewPlaylist = false
    @State private var newPlaylistName = ""
    /// The SMB server currently being edited (presents the edit sheet).
    @State private var editingSMB: SMBServerConfig?
    /// Each source's current folder stack, so re-selecting a library returns to
    /// the most recent location it was left at.
    @State private var sourcePaths: [String: [FolderRoute]] = [:]
    /// The deepest folder stack seen per source. Survives the NavigationStack
    /// teardown (which writes an empty path back through the live binding when a
    /// source is switched away), so re-selecting a source can restore it.
    @State private var rememberedSourcePaths: [String: [FolderRoute]] = [:]
    /// The file "Locate File" should scroll to, once its folder is open.
    @State private var locateFilePath: String?
    /// Set briefly while a "Locate File" action drives the selection change so we
    /// don't clear `locateFilePath` in the resulting `onChange`.
    @State private var pendingLocate = false

    var body: some View {
        VStack(spacing: 0) {
            RemotePairingBanner()
                .environmentObject(remoteServer)

            NavigationSplitView {
                sidebar
            } detail: {
                detail
            }

            // The Now Playing bar is a real layout sibling docked at the bottom,
            // below the split view — so it's always visible, can't be covered by a
            // long list or slip under the sidebar, and needs no scroll-clearance
            // hacks (the lists simply end above it).
            nowPlayingBar
        }
        .onChange(of: selection) { _, newValue in
            if pendingLocate {
                pendingLocate = false
            } else {
                locateFilePath = nil
            }
            // Restore a source's remembered folder when it's (re-)selected — but
            // only on the selection change, so popping to root within a source
            // doesn't immediately re-push.
            if case .source(let id) = newValue,
               (sourcePaths[id]?.isEmpty ?? true),
               let remembered = rememberedSourcePaths[id], !remembered.isEmpty {
                sourcePaths[id] = remembered
            }
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
        .sheet(item: $editingSMB) { config in
            AddSMBServerView(editing: config)
        }
        // The full player covers the whole screen on iPad / Mac (a regular-width
        // sheet would otherwise float as a centred card), while iPhone keeps the
        // swipe-down sheet.
        .modifier(PlayerPresentation(isPresented: $showingPlayer,
                                     fullScreen: horizontalSizeClass == .regular) {
            PlayerView(onShowQueue: showQueue)
                .environmentObject(player)
                .environmentObject(artwork)
                .environmentObject(playlists)
        })
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
    }


    /// The floating Now Playing bar, shown when something is loaded.
    @ViewBuilder
    private var nowPlayingBar: some View {
        if player.currentTrack != nil {
            NowPlayingBar(
                onTap: { showingPlayer = true },
                onShowQueue: showQueue
            )
        }
    }

    private func showQueue() {
        showingPlayer = false
        selection = .queue
    }

    /// Translucent "liquid glass" backing for the sidebar: a blur material with a
    /// faint accent wash, so the window/content shows through.
    private var sidebarGlass: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            LinearGradient(
                colors: [Color.accentColor.opacity(0.10), .clear, Color.accentColor.opacity(0.05)],
                startPoint: .top, endPoint: .bottom
            )
        }
        .ignoresSafeArea()
    }

    private var sidebar: some View {
        List(selection: $selection) {
            Section("Playback") {
                Label {
                    HStack {
                        Text("Queue")
                        if !player.queue.isEmpty {
                            Text("\(player.queue.count)")
                                .foregroundStyle(.secondary)
                        }
                    }
                } icon: {
                    Image(systemName: "list.bullet")
                }
                .tag(SidebarSelection.queue)

                Label {
                    HStack {
                        Text("History")
                        if !player.history.isEmpty {
                            Text("\(player.history.count)")
                                .foregroundStyle(.secondary)
                        }
                    }
                } icon: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .tag(SidebarSelection.history)
            }

            Section("Library") {
                ForEach(registry.sources, id: \.id) { source in
                    HStack {
                        Label(source.displayName, systemImage: source.symbolName)
                        if let scan = registry.libraryScans[source.id], scan.isScanning {
                            Spacer()
                            ProgressView().controlSize(.small)
                            Text("\(scan.foldersScanned)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                        .tag(SidebarSelection.source(source.id))
                        .contextMenu {
                            if let smb = source as? SMBFileSource {
                                Button {
                                    editingSMB = smb.config
                                } label: {
                                    Label("Edit…", systemImage: "pencil")
                                }
                            }
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
        .scrollContentBackground(.hidden)
        .background(sidebarGlass)
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
        switch selection {
        case .queue:
            NavigationStack {
                QueueView(onLocate: locate)
                    .environmentObject(player)
            }
        case .history:
            NavigationStack {
                HistoryView(onLocate: locate)
                    .environmentObject(player)
                    .environmentObject(playlists)
            }
        case .source(let id):
            if let source = registry.source(for: id) {
                NavigationStack(path: pathBinding(for: id)) {
                    FolderBrowserView(
                        source: source, path: "", title: source.displayName,
                        focusFilePath: locateFilePath, pushFolder: pushFolder
                    )
                    .navigationDestination(for: FolderRoute.self) { route in
                        if let routeSource = registry.source(for: route.sourceID) {
                            FolderBrowserView(
                                source: routeSource, path: route.path, title: route.title,
                                focusFilePath: locateFilePath, pushFolder: pushFolder
                            )
                            .environmentObject(player)
                            .environmentObject(playlists)
                        }
                    }
                }
                .id(id)
            } else {
                NavigationStack { unavailable }
            }
        case .playlist(let id):
            NavigationStack {
                PlaylistDetailView(playlistID: id, onLocate: locate)
            }
        case nil:
            NavigationStack { unavailable }
        }
    }

    private var unavailable: some View {
        EmptyStateView(
            title: "Select a Source",
            systemImage: "music.note.list",
            message: "Choose a folder, SMB server, or playlist to start listening."
        )
    }

    // MARK: - Folder navigation memory & Locate File

    /// Binds a source's remembered navigation stack so browsing it updates the
    /// stored location and re-selecting the source restores it.
    private func pathBinding(for id: String) -> Binding<[FolderRoute]> {
        Binding(
            get: { sourcePaths[id] ?? [] },
            set: { newValue in
                let old = sourcePaths[id] ?? []
                sourcePaths[id] = newValue
                // Remember only when navigating deeper (the path grows). The
                // teardown on a source switch pops/clears the path, and recording
                // those shrinks would leave the saved location one level too
                // shallow (or empty).
                if newValue.count > old.count { rememberedSourcePaths[id] = newValue }
            }
        )
    }

    /// Pushes a sub-folder (used by Catalyst's programmatic open).
    private func pushFolder(_ route: FolderRoute) {
        var paths = sourcePaths[route.sourceID] ?? []
        paths.append(route)
        sourcePaths[route.sourceID] = paths
        rememberedSourcePaths[route.sourceID] = paths
    }

    /// "Locate File": switch to the track's source and open the folder that holds
    /// it, scrolling the file into view.
    private func locate(_ track: Track) {
        let folder = (track.path as NSString).deletingLastPathComponent
        sourcePaths[track.sourceID] = folderRoutes(sourceID: track.sourceID, folder: folder)
        locateFilePath = track.path
        pendingLocate = true
        selection = .source(track.sourceID)
    }

    /// Builds the chain of folder routes leading down to `folder`.
    private func folderRoutes(sourceID: String, folder: String) -> [FolderRoute] {
        guard !folder.isEmpty else { return [] }
        var routes: [FolderRoute] = []
        var accumulated = ""
        for component in folder.split(separator: "/").map(String.init) {
            accumulated = accumulated.isEmpty ? component : accumulated + "/" + component
            routes.append(FolderRoute(sourceID: sourceID, path: accumulated, title: component))
        }
        return routes
    }

}

/// Presents the full player as a full-screen cover (iPad / Mac, so it covers the
/// whole screen) or a sheet (iPhone, keeping swipe-to-dismiss).
private struct PlayerPresentation<SheetContent: View>: ViewModifier {
    @Binding var isPresented: Bool
    let fullScreen: Bool
    @ViewBuilder var sheet: () -> SheetContent

    func body(content: Content) -> some View {
        if fullScreen {
            content.fullScreenCover(isPresented: $isPresented, content: sheet)
        } else {
            content.sheet(isPresented: $isPresented, content: sheet)
        }
    }
}

private struct PlaylistSidebarRow: View {
    let playlist: Playlist

    @EnvironmentObject private var playlists: PlaylistManager
    @State private var isDropTarget = false

    private var isFavorites: Bool { playlist.id == PlaylistManager.favoritesID }

    var body: some View {
        Label {
            Text(playlist.name)
            Text("\(playlist.entries.count)")
                .foregroundStyle(.secondary)
        } icon: {
            Image(systemName: isFavorites ? "star.fill" : "music.note.list")
                .foregroundStyle(isFavorites ? Color.yellow : Color.accentColor)
        }
        .listRowBackground(isDropTarget ? Color.accentColor.opacity(0.15) : nil)
        .dropDestination(for: Track.self) { tracks, _ in
            for track in tracks {
                playlists.add(track, to: playlist.id)
            }
            return true
        } isTargeted: { isDropTarget = $0 }
        .contextMenu {
            if !isFavorites {
                Button(role: .destructive) {
                    playlists.delete(playlist.id)
                } label: {
                    Label("Delete Playlist", systemImage: "trash")
                }
            }
        }
    }
}
