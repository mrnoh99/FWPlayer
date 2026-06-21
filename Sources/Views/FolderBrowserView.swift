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
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var trackToAdd: Track?
    @State private var selectedItemPath: String?
    @State private var scrollTarget: String?
    @State private var focusRevertTask: Task<Void, Never>?
    /// The sub-folder last opened from here, so returning scrolls back to it
    /// instead of jumping to the top.
    @State private var lastOpenedChildPath: String?

    private var audioItems: [FileItem] { items.filter { $0.kind == .audio } }

    var body: some View {
        Group {
            if isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                    Text("Opening \(title)…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
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
        // The detail's value-based NavigationStack already supplies a standard
        // back button; an extra custom one here showed up as a second chevron
        // (bumped to the trailing edge inside the split view). The in-list parent
        // row below covers the explicit "go up" affordance on Catalyst.
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
        ScrollViewReader { proxy in
            listContent
                #if targetEnvironment(macCatalyst)
                .listStyle(.inset)
                #endif
                .refreshable { await reload(forceRefresh: true) }
                // Keep the focused/playing row, and the "Locate File" target,
                // centered. ScrollViewReader is more reliable than
                // .scrollPosition, whose two-way binding gets reset to the top
                // row on first layout (so Locate never centered).
                .onChange(of: scrollTarget) { _, target in
                    guard let target else { return }
                    withAnimation { proxy.scrollTo(target, anchor: .center) }
                }
                .onChange(of: isLoading) { _, loading in
                    if !loading { centerLocatedFile(using: proxy) }
                }
                .onAppear {
                    centerLocatedFile(using: proxy)
                    restoreLastOpenedChild(using: proxy)
                }
        }
    }

    @ViewBuilder
    private var listContent: some View {
        // A plain List (no selection binding). On Catalyst a List(selection:)
        // claims the single click as a row *selection* (the highlight moves but
        // nothing opens — you'd have to press Return), which defeats the row's
        // Button. Without it the Button gets the click and opens on one tap.
        List {
            listRows
        }
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
                    onPlay: { openFolder(at: item.path, name: item.name) }
                ) {
                    FolderRow(name: item.name)
                }
                .tag(item.path)
                #else
                NavigationLink(value: FolderRoute(sourceID: source.id, path: item.path, title: item.name)) {
                    Label(item.name, systemImage: "folder")
                }
                .simultaneousGesture(TapGesture().onEnded { lastOpenedChildPath = item.path })
                #endif
            case .audio:
                PlaybackRowInteraction(
                    isHighlighted: isFocused(item),
                    onPlay: { playFromQueue(startingAt: item) }
                ) {
                    TrackRow(
                        item: item,
                        sourceID: source.id,
                        isCurrent: isCurrent(item),
                        isPlaying: player.isPlaying,
                        directURL: source.directURL(forPath: item.path),
                        isFavorite: playlists.isFavorite(Track(sourceID: source.id, item: item)),
                        onToggleFavorite: { playlists.toggleFavorite(Track(sourceID: source.id, item: item)) },
                        onPlayNow: { player.play(tracks: [Track(sourceID: source.id, item: item)], startAt: 0) },
                        onPlayFromHere: { playFromQueue(startingAt: item) },
                        onPlayNext: { player.playNext(Track(sourceID: source.id, item: item)) },
                        onAddToQueue: { player.enqueue(tracks: [Track(sourceID: source.id, item: item)]) },
                        onAddToPlaylist: { trackToAdd = Track(sourceID: source.id, item: item) }
                    )
                }
                .id(item.path)
                #if targetEnvironment(macCatalyst)
                .tag(item.path)
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
        lastOpenedChildPath = path
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

    private func reload(forceRefresh: Bool = false) async {
        isLoading = true
        loadError = nil
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
        } catch {
            loadError = userFacingLoadError(error)
            items = []
            isLoading = false
        }
        syncFocusFromPlayer()
        applyLocateFocusIfNeeded()
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

    /// On returning from a sub-folder, scrolls back to the folder that was opened
    /// so the list resumes where it was rather than at the top.
    private func restoreLastOpenedChild(using proxy: ScrollViewProxy) {
        guard let child = lastOpenedChildPath,
              items.contains(where: { $0.path == child }) else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            proxy.scrollTo(child, anchor: .center)
        }
    }

    /// Scrolls the "Locate File" target to the centre once the folder's rows are
    /// laid out. Runs after a short delay so the List has rendered the row the
    /// proxy needs to find.
    private func centerLocatedFile(using proxy: ScrollViewProxy) {
        guard let focusFilePath,
              (focusFilePath as NSString).deletingLastPathComponent == path,
              items.contains(where: { $0.path == focusFilePath }) else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            withAnimation { proxy.scrollTo(focusFilePath, anchor: .center) }
        }
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
    var isPlaying: Bool = false
    let directURL: URL?
    var isFavorite: Bool = false
    var onToggleFavorite: (() -> Void)? = nil
    var onPlayNow: (() -> Void)? = nil
    var onPlayFromHere: (() -> Void)? = nil
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
                    HStack(spacing: 4) {
                        if isCurrent {
                            Image(systemName: isPlaying ? "speaker.wave.2.fill" : "pause.fill")
                                .font(.caption)
                                .foregroundStyle(.tint)
                        }
                        Text((item.name as NSString).deletingPathExtension)
                            .fontWeight(isCurrent ? .semibold : .regular)
                            .lineLimit(1)
                    }
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if !timeText.isEmpty {
                    Text(timeText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                if onPlayNow != nil || onPlayNext != nil || onAddToQueue != nil {
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
                        if let onToggleFavorite {
                            Button(role: isFavorite ? .destructive : nil, action: onToggleFavorite) {
                                Label(isFavorite ? "Remove from Favorites" : "Add to Favorites",
                                      systemImage: isFavorite ? "star.slash" : "star")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .foregroundStyle(.secondary)
                            .frame(width: 30, height: 30)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("More")
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 10)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 6)
        .background(isCurrent ? Color.accentColor.opacity(0.22) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .task(id: directURL?.path) {
            guard let directURL else { return }
            sampleRate = await AudioFormatReader.sampleRate(for: directURL)
            duration = await AudioFormatReader.duration(for: directURL)
        }
    }
}
