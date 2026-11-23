import SwiftUI

/// Finds folders and audio files by name across every source: type part of an album, artist or
/// track name. It searches the folder listings FWPlayer has already scanned (the same ones that
/// make browsing instant), so it needs no network and no tags.
struct LibrarySearchView: View {
    @EnvironmentObject private var registry: SourceRegistry
    @EnvironmentObject private var player: AudioPlayer

    /// Opens a folder in its source's browser (source id, folder path).
    var onOpenFolder: (String, String) -> Void
    /// Reveals a track's file in its folder.
    var onLocate: (Track) -> Void

    @State private var query = ""
    @State private var groups: [SearchGroup] = []
    @State private var searching = false
    @State private var searchTask: Task<Void, Never>?
    @State private var trackToAdd: Track?

    private struct SearchGroup: Identifiable {
        let id: String            // source id
        let name: String
        let items: [FileItem]
    }

    private static let resultLimit = 300

    var body: some View {
        content
            .navigationTitle("Search")
            #if !targetEnvironment(macCatalyst)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .searchable(text: $query, prompt: "Folders and file names")
            .onChange(of: query) { _, new in schedule(new) }
            .sheet(item: $trackToAdd) { track in
                AddToPlaylistView(track: track)
            }
    }

    @ViewBuilder
    private var content: some View {
        if LibrarySearch.terms(from: query).isEmpty {
            EmptyStateView(
                title: "Search Your Library",
                systemImage: "magnifyingglass",
                message: "Type part of an artist, album or track name. It searches the folders FWPlayer has already scanned — after adding a folder or server, wait for the scan (the spinner in the sidebar) to finish."
            )
        } else if groups.isEmpty {
            if searching {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                EmptyStateView(
                    title: "No Results",
                    systemImage: "magnifyingglass",
                    message: "Nothing in the scanned folders matches “\(query)”. Try fewer words."
                )
            }
        } else {
            List {
                ForEach(groups) { group in
                    Section(group.name) {
                        ForEach(group.items) { item in
                            row(item, sourceID: group.id)
                        }
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    // MARK: - Rows

    private func row(_ item: FileItem, sourceID: String) -> some View {
        let isFolder = item.kind == .directory
        let parent = (item.path as NSString).deletingLastPathComponent
        return Button {
            open(item, sourceID: sourceID)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isFolder ? "folder.fill" : "music.note")
                    .foregroundStyle(isFolder ? Color.accentColor : Color.secondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(isFolder ? item.name : (item.name as NSString).deletingPathExtension)
                        .lineLimit(1)
                    if !parent.isEmpty {
                        Text(parent)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if isFolder {
                Button { openFolderMenuAction(item, sourceID: sourceID) } label: {
                    Label("Open Folder", systemImage: "folder")
                }
                Button { playFolder(item, sourceID: sourceID, enqueue: false) } label: {
                    Label("Play Folder", systemImage: "play.fill")
                }
                Button { playFolder(item, sourceID: sourceID, enqueue: true) } label: {
                    Label("Add Folder to Queue", systemImage: "text.badge.plus")
                }
            } else {
                let track = Track(sourceID: sourceID, item: item)
                Button { player.play(tracks: [track], startAt: 0) } label: {
                    Label("Play Now", systemImage: "play.fill")
                }
                Button { player.playNext(track) } label: {
                    Label("Play Next", systemImage: "text.insert")
                }
                Button { player.enqueue(tracks: [track]) } label: {
                    Label("Add to Queue", systemImage: "text.badge.plus")
                }
                Button { trackToAdd = track } label: {
                    Label("Add to Playlist…", systemImage: "music.note.list")
                }
                Button { onLocate(track) } label: {
                    Label("Show in Folder", systemImage: "folder")
                }
            }
        }
    }

    private func open(_ item: FileItem, sourceID: String) {
        if item.kind == .directory {
            onOpenFolder(sourceID, item.path)
        } else {
            player.play(tracks: [Track(sourceID: sourceID, item: item)], startAt: 0)
        }
    }

    private func openFolderMenuAction(_ item: FileItem, sourceID: String) {
        onOpenFolder(sourceID, item.path)
    }

    private func playFolder(_ item: FileItem, sourceID: String, enqueue: Bool) {
        guard let source = registry.source(for: sourceID) else { return }
        Task { @MainActor in
            guard let items = try? await source.audioItems(in: item.path, recursive: true),
                  !items.isEmpty else { return }
            let tracks = items.map { Track(sourceID: sourceID, item: $0) }
            if enqueue {
                player.enqueue(tracks: tracks)
            } else {
                player.play(tracks: tracks, startAt: 0)
            }
        }
    }

    // MARK: - Searching

    /// Runs the search a moment after typing stops, replacing any search still running.
    private func schedule(_ text: String) {
        searchTask?.cancel()
        let terms = LibrarySearch.terms(from: text)
        guard !terms.isEmpty else {
            groups = []
            searching = false
            return
        }
        searching = true
        searchTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            var found: [SearchGroup] = []
            for source in registry.sources {
                let items = await source.search(terms: terms, limit: Self.resultLimit)
                if Task.isCancelled { return }
                if !items.isEmpty {
                    found.append(SearchGroup(id: source.id, name: source.displayName, items: items))
                }
            }
            groups = found
            searching = false
        }
    }
}
