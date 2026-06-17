import SwiftUI

/// Root layout: a sidebar listing sources, a detail browser, and a persistent
/// Now Playing bar pinned to the bottom.
struct ContentView: View {
    @EnvironmentObject private var registry: SourceRegistry
    @EnvironmentObject private var player: AudioPlayer

    @State private var selection: String?
    @State private var showingFolderPicker = false
    @State private var showingAddSMB = false
    @State private var showingPlayer = false

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
                        .tag(source.id)
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
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        NavigationStack {
            if let id = selection, let source = registry.source(for: id) {
                FolderBrowserView(source: source, path: "", title: source.displayName)
            } else {
                EmptyStateView(
                    title: "Select a Source",
                    systemImage: "music.note.list",
                    message: "Choose a folder or SMB server to browse your FLAC and WAV files."
                )
            }
        }
    }
}
