import SwiftUI

/// A folder location pushed onto a source's navigation stack. Hashable so it can
/// drive a value-based `NavigationStack` path (and be restored later).
struct FolderRoute: Hashable {
    let sourceID: String
    let path: String
    let title: String
}

/// Lists the contents of one directory within a `FileSource`. Tapping a folder
/// pushes another browser; tapping an audio file plays the folder as a queue
/// starting at that file.
struct FolderBrowserView: View {
    let source: any FileSource
    let path: String
    let title: String
    /// When this folder is the one containing `focusFilePath`, that file is
    /// highlighted and scrolled into view on load (used by "Locate File").
    var focusFilePath: String? = nil
    /// Pushes a sub-folder onto the navigation stack (Catalyst's programmatic
    /// open; iOS uses value-based `NavigationLink`s instead).
    var pushFolder: ((FolderRoute) -> Void)? = nil

    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var playlists: PlaylistManager
    #if targetEnvironment(macCatalyst)
    @Environment(\.dismiss) private var dismiss
    #endif

    @State private var items: [FileItem] = []
    @State private var hasPlayableContent = false
    @State private var subfoldersHaveAudio = false
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var trackToAdd: Track?
    @State private var selectedItemPath: String?
    @State private var scrollTarget: String?
    @State private var focusRevertTask: Task<Void, Never>?
    @State private var playabilityTask: Task<Void, Never>?

    private var audioItems: [FileItem] { items.filter { $0.kind == .audio } }

    /// The folder's Play button is enabled only when this folder has audio and no
    /// subfolder holds playable music (so playing it captures everything here).
    private var canPlayFolder: Bool { !audioItems.isEmpty && !subfoldersHaveAudio }

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let loadError {
                EmptyStateView(title: "Couldn't Load Folder",
                               systemImage: "exclamationmark.triangle",
                               message: loadError)
            } else {
                // Always open the folder — even with no audio — so its subfolders
                // are browsable. An empty folder shows an inline hint in the list.
                list
            }
        }
        .navigationTitle(title)
        .toolbar {
            #if targetEnvironment(macCatalyst)
            if canGoToParent {
                ToolbarItem(placement: .navigation) {
                    Button { dismiss() } label: {
                        Label("Parent Folder", systemImage: "chevron.left")
                    }
                }
            }
            #endif
            if hasPlayableContent {
                ToolbarItem(placement: .primaryAction) {
                    Button { playFolder() } label: {
                        Label("Play", systemImage: "play.fill")
                    }
                    .disabled(!canPlayFolder)
                }
            }
        }
        .task(id: path) {
            await reload()
        }
        .onChange(of: player.currentTrack?.id) {
            Task { @MainActor in syncFocusFromPlayer() }
        }
        .onChange(of: player.transportEventID) {
            Task { @MainActor in syncFocusFromPlayer() }
        }
        .onChange(of: selectedItemPath) { _, new in
            guard let new else { return }
            scrollTarget = new
            if new == currentPlayingPathInList || new == focusFilePath {
                ListFocusBehavior.cancelRevert(task: &focusRevertTask)
            } else {
                scheduleFocusRevert()
            }
        }
        #if targetEnvironment(macCatalyst)
        .onKeyPress(.return) {
            openSelectedFolderIfNeeded()
        }
        #endif
        .sheet(item: $trackToAdd) { track in
            AddToPlaylistView(track: track)
        }
    }

    private var list: some View {
        listContent
            #if targetEnvironment(macCatalyst)
            .listStyle(.inset)
            #endif
            .scrollPosition(id: $scrollTarget, anchor: .center)
            .refreshable { await reload(forceRefresh: true) }
    }

    @ViewBuilder
    private var listContent: some View {
        #if targetEnvironment(macCatalyst)
        List(selection: $selectedItemPath) {
            listRows
        }
        #else
        List {
            listRows
        }
        #endif
    }

    @ViewBuilder
    private var listRows: some View {
        #if targetEnvironment(macCatalyst)
        if canGoToParent {
            Button { dismiss() } label: {
                Label(parentFolderLabel, systemImage: "arrow.turn.up.left")
            }
            .tag("__parent__")
        }
        #endif
        if items.isEmpty {
            Text("No audio files in this folder.")
                .foregroundStyle(.secondary)
        }
        ForEach(items) { item in
            switch item.kind {
            case .directory:
                #if targetEnvironment(macCatalyst)
                PlaybackRowInteraction(
                    isHighlighted: isFocused(item),
                    onSelect: { focus(on: item, transient: false) },
                    onPlay: { openFolder(at: item.path, name: item.name) }
                ) {
                    FolderRow(name: item.name)
                }
                .tag(item.path)
                .overlay {
                    DoubleClickDetector(
                        onSingleClick: { focus(on: item, transient: false) },
                        onDoubleClick: { openFolder(at: item.path, name: item.name) }
                    )
                }
                .contextMenu {
                    Button {
                        Task { await playFolder(at: item.path) }
                    } label: {
                        Label("Play Folder", systemImage: "play.fill")
                    }
                }
                #else
                NavigationLink(value: FolderRoute(sourceID: source.id, path: item.path, title: item.name)) {
                    Label(item.name, systemImage: "folder")
                }
                .contextMenu {
                    Button {
                        Task { await playFolder(at: item.path) }
                    } label: {
                        Label("Play Folder", systemImage: "play.fill")
                    }
                }
                #endif
            case .audio:
                PlaybackRowInteraction(
                    isHighlighted: isFocused(item),
                    onSelect: { focus(on: item, transient: false) },
                    onPlay: { player.playNext(Track(sourceID: source.id, item: item)) }
                ) {
                    TrackRow(
                        item: item,
                        sourceID: source.id,
                        isCurrent: isCurrent(item),
                        directURL: source.directURL(forPath: item.path),
                        isFavorite: playlists.isFavorite(Track(sourceID: source.id, item: item)),
                        onToggleFavorite: { playlists.toggleFavorite(Track(sourceID: source.id, item: item)) },
                        onPlayNow: { playFromQueue(startingAt: item) },
                        onPlayNext: { player.playNext(Track(sourceID: source.id, item: item)) },
                        onAddToQueue: { player.enqueue(tracks: [Track(sourceID: source.id, item: item)]) },
                        onAddToPlaylist: { trackToAdd = Track(sourceID: source.id, item: item) }
                    )
                }
                .id(item.path)
                #if targetEnvironment(macCatalyst)
                .tag(item.path)
                .overlay {
                    DoubleClickDetector(
                        onSingleClick: { focus(on: item, transient: false) },
                        onDoubleClick: { playFromQueue(startingAt: item) }
                    )
                }
                #endif
                .swipeActions(edge: .trailing) {
                    Button {
                        player.enqueue(tracks: [Track(sourceID: source.id, item: item)])
                    } label: {
                        Label("Queue", systemImage: "text.line.first.and.arrowtriangle.forward")
                    }
                    .tint(.blue)
                    Button {
                        trackToAdd = Track(sourceID: source.id, item: item)
                    } label: {
                        Label("Playlist", systemImage: "text.badge.plus")
                    }
                    .tint(.accentColor)
                }
                .draggable(Track(sourceID: source.id, item: item))
                .contextMenu {
                    Button {
                        player.enqueue(tracks: [Track(sourceID: source.id, item: item)])
                    } label: {
                        Label("Add to Queue", systemImage: "text.line.first.and.arrowtriangle.forward")
                    }
                    Button {
                        trackToAdd = Track(sourceID: source.id, item: item)
                    } label: {
                        Label("Add to Playlist", systemImage: "text.badge.plus")
                    }
                }
            case .other:
                EmptyView()
            }
        }
    }

    private func folderName(for path: String) -> String {
        (path as NSString).lastPathComponent
    }

    private var canGoToParent: Bool { !path.isEmpty }

    private var parentPath: String {
        (path as NSString).deletingLastPathComponent
    }

    private var parentFolderLabel: String {
        parentPath.isEmpty ? source.displayName : folderName(for: parentPath)
    }

    #if targetEnvironment(macCatalyst)
    private func openSelectedFolderIfNeeded() -> KeyPress.Result {
        guard let selectedItemPath,
              let item = items.first(where: { $0.path == selectedItemPath }),
              item.kind == .directory else {
            return .ignored
        }
        openFolder(at: item.path, name: item.name)
        return .handled
    }

    private func openFolder(at path: String, name: String) {
        ListFocusBehavior.cancelRevert(task: &focusRevertTask)
        pushFolder?(FolderRoute(sourceID: source.id, path: path, title: name))
    }
    #endif

    private func syncFocusFromPlayer() {
        ListFocusBehavior.cancelRevert(task: &focusRevertTask)
        guard let path = currentPlayingPathInList else { return }
        selectedItemPath = path
        scrollTarget = path
    }

    private var currentPlayingPathInList: String? {
        guard let current = player.currentTrack,
              current.sourceID == source.id,
              items.contains(where: { $0.path == current.path }) else { return nil }
        return current.path
    }

    private func isFocused(_ item: FileItem) -> Bool {
        selectedItemPath == item.path
    }

    private func focus(on item: FileItem, transient: Bool = true) {
        selectedItemPath = item.path
        scrollTarget = item.path
        if transient {
            scheduleFocusRevert()
        }
    }

    private func scheduleFocusRevert() {
        ListFocusBehavior.scheduleRevert(
            task: &focusRevertTask,
            to: currentPlayingPathInList,
            isPlaybackActive: player.currentTrack != nil,
            currentFocusID: selectedItemPath
        ) { playingPath in
            selectedItemPath = playingPath
            scrollTarget = playingPath
        }
    }

    private func isCurrent(_ item: FileItem) -> Bool {
        guard let current = player.currentTrack else { return false }
        return current.sourceID == source.id && current.path == item.path
    }

    private func playFromQueue(startingAt item: FileItem) {
        let tracks = audioItems.map { Track(sourceID: source.id, item: $0) }
        guard let index = audioItems.firstIndex(of: item) else { return }
        ListFocusBehavior.cancelRevert(task: &focusRevertTask)
        focus(on: item, transient: false)
        player.play(tracks: tracks, startAt: index)
    }

    /// Plays this folder's direct audio (used by the folder Play button, which is
    /// only enabled when no subfolder holds music).
    private func playFolder() {
        let tracks = audioItems.map { Track(sourceID: source.id, item: $0) }
        guard !tracks.isEmpty else { return }
        player.play(tracks: tracks, startAt: 0)
    }

    /// Plays every audio under a subfolder recursively ("Play Folder" on a folder row).
    private func playFolder(at folderPath: String) async {
        do {
            let items = try await source.audioItems(in: folderPath, recursive: true)
            guard !items.isEmpty else { return }
            let tracks = items.map { Track(sourceID: source.id, item: $0) }
            player.play(tracks: tracks, startAt: 0)
        } catch {
            loadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func reload(forceRefresh: Bool = false) async {
        playabilityTask?.cancel()
        isLoading = true
        loadError = nil
        hasPlayableContent = false
        subfoldersHaveAudio = false
        do {
            items = if forceRefresh {
                try await source.refresh(path: path)
            } else {
                try await source.list(path: path)
            }
            if items.isEmpty, !forceRefresh, !path.isEmpty {
                items = try await refreshedIfAdvertisedInParent(current: items)
            }
            isLoading = false
            updatePlayabilityHints()
        } catch {
            loadError = userFacingLoadError(error)
            items = []
            isLoading = false
        }
        syncFocusFromPlayer()
        applyLocateFocusIfNeeded()
    }

    /// Updates Play toolbar state without blocking the folder list from appearing.
    private func updatePlayabilityHints() {
        let directAudio = items.contains(where: { $0.kind == .audio })
        let hasSubfolders = items.contains(where: { $0.kind == .directory })
        if directAudio && !hasSubfolders {
            hasPlayableContent = true
            subfoldersHaveAudio = false
            return
        }
        if !directAudio && !hasSubfolders {
            hasPlayableContent = false
            subfoldersHaveAudio = false
            return
        }
        playabilityTask = Task(priority: .utility) {
            let subs = await source.subfolderHasPlayableAudio(in: path)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                subfoldersHaveAudio = subs
                hasPlayableContent = directAudio || subs
            }
        }
    }

    /// Re-reads from disk when a stale cache returned empty for a folder the parent
    /// listing still advertises.
    private func refreshedIfAdvertisedInParent(current: [FileItem]) async throws -> [FileItem] {
        guard current.isEmpty, !path.isEmpty else { return current }
        let parent = (path as NSString).deletingLastPathComponent
        guard let parentEntries = try? await source.list(path: parent),
              parentEntries.contains(where: { $0.kind == .directory && $0.path == path }) else {
            return current
        }
        return try await source.refresh(path: path)
    }

    private func userFacingLoadError(_ error: Error) -> String {
        if let smb = source as? SMBFileSource {
            return SMBFileSource.userFacingMessage(for: error)
        }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    /// If this folder holds the "Locate File" target, highlight and scroll to it.
    private func applyLocateFocusIfNeeded() {
        guard let focusFilePath,
              (focusFilePath as NSString).deletingLastPathComponent == path,
              items.contains(where: { $0.path == focusFilePath }) else { return }
        ListFocusBehavior.cancelRevert(task: &focusRevertTask)
        selectedItemPath = focusFilePath
        scrollTarget = focusFilePath
    }
}

#if targetEnvironment(macCatalyst)
private struct FolderRow: View {
    let name: String

    var body: some View {
        Label(name, systemImage: "folder")
    }
}
#endif

private struct TrackRow: View {
    let item: FileItem
    let sourceID: String
    let isCurrent: Bool
    let directURL: URL?
    var isFavorite: Bool = false
    var onToggleFavorite: (() -> Void)? = nil
    var onPlayNow: (() -> Void)? = nil
    var onPlayNext: (() -> Void)? = nil
    var onAddToQueue: (() -> Void)? = nil
    var onAddToPlaylist: (() -> Void)? = nil

    @State private var sampleRate: Double?
    @State private var duration: Double?

    private var track: Track { Track(sourceID: sourceID, item: item) }

    /// Album · format line under the title (artist/album when the metadata is
    /// known, otherwise the audio format — meaningful for a lossless player).
    private var subtitle: String {
        var parts: [String] = [item.fileExtension.uppercased()]
        if let sampleRate { parts.append(AudioFormatReader.formatSampleRate(sampleRate)) }
        return parts.joined(separator: " · ")
    }

    /// The "Time" column: track length once known, otherwise the file size.
    private var timeText: String {
        if let duration { return AudioFormatReader.formatDuration(duration) }
        if let size = item.size { return ByteCountFormatter.string(fromByteCount: size, countStyle: .file) }
        return ""
    }

    var body: some View {
        HStack(spacing: 8) {
            // Favorite star sits in a leading gutter, outside the row highlight.
            if let onToggleFavorite {
                Button(action: onToggleFavorite) {
                    Image(systemName: isFavorite ? "star.fill" : "star")
                        .font(.footnote)
                        .foregroundStyle(isFavorite ? Color.yellow : Color.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(isFavorite ? "Remove from Favorites" : "Add to Favorites")
            }

            HStack(spacing: 10) {
                ArtworkThumbnail(track: track, directURL: directURL, isCurrent: isCurrent)

                VStack(alignment: .leading, spacing: 2) {
                    Text((item.name as NSString).deletingPathExtension)
                        .fontWeight(isCurrent ? .semibold : .regular)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(isCurrent ? Color.white.opacity(0.85) : Color.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if !timeText.isEmpty {
                    Text(timeText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(isCurrent ? Color.white.opacity(0.9) : Color.secondary)
                }

                if onPlayNow != nil || onPlayNext != nil || onAddToQueue != nil {
                    Menu {
                        if let onPlayNow {
                            Button(action: onPlayNow) { Label("Play Now", systemImage: "play.fill") }
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
                        if let onToggleFavorite {
                            Button(action: onToggleFavorite) {
                                Label(isFavorite ? "Remove from Favorites" : "Add to Favorites",
                                      systemImage: isFavorite ? "star.slash" : "star")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .foregroundStyle(isCurrent ? Color.white : Color.secondary)
                            .frame(width: 30, height: 30)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("More")
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 10)
            .foregroundStyle(isCurrent ? Color.white : Color.primary)
            .background(isCurrent ? Color.accentColor : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .contentShape(Rectangle())
        .task(id: directURL?.path) {
            guard let directURL else { return }
            sampleRate = await AudioFormatReader.sampleRate(for: directURL)
            duration = await AudioFormatReader.duration(for: directURL)
        }
    }
}
