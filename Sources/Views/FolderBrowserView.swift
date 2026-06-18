import SwiftUI

private struct FolderNavigationTarget: Identifiable, Hashable {
    let path: String
    var id: String { path }
}

/// Lists the contents of one directory within a `FileSource`. Tapping a folder
/// pushes another browser; tapping an audio file plays the folder as a queue
/// starting at that file.
struct FolderBrowserView: View {
    let source: any FileSource
    let path: String
    let title: String

    @EnvironmentObject private var player: AudioPlayer
    #if targetEnvironment(macCatalyst)
    @Environment(\.dismiss) private var dismiss
    #endif

    @State private var items: [FileItem] = []
    @State private var playableTracks: [FileItem] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var trackToAdd: Track?
    @State private var selectedItemPath: String?
    @State private var scrollTarget: String?
    @State private var folderToOpen: FolderNavigationTarget?
    @State private var openingFolderPath: String?
    @State private var focusRevertTask: Task<Void, Never>?

    private var audioItems: [FileItem] { items.filter { $0.kind == .audio } }

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let loadError {
                EmptyStateView(title: "Couldn't Load Folder",
                               systemImage: "exclamationmark.triangle",
                               message: loadError)
            } else if items.isEmpty {
                if canGoToParent {
                    list
                } else {
                    EmptyStateView(title: "No Audio Here",
                                   systemImage: "music.note",
                                   message: "This folder has no FLAC or WAV files.")
                }
            } else {
                ZStack {
                    list
                    if openingFolderPath != nil {
                        ProgressView("Opening…")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(.ultraThinMaterial)
                    }
                }
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
            if hasPlayableSelection {
                ToolbarItem(placement: .primaryAction) {
                    Button { playSelection() } label: {
                        Label("Play", systemImage: "play.fill")
                    }
                }
            }
        }
        .task(id: path) {
            folderToOpen = nil
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
            if new == currentPlayingPathInList {
                ListFocusBehavior.cancelRevert(task: &focusRevertTask)
            } else {
                scheduleFocusRevert()
            }
        }
        #if targetEnvironment(macCatalyst)
        .navigationDestination(item: $folderToOpen) { target in
            FolderBrowserView(
                source: source,
                path: target.path,
                title: folderName(for: target.path)
            )
            .environmentObject(player)
            .onAppear { openingFolderPath = nil }
        }
        .onChange(of: folderToOpen) { _, new in
            if new == nil { openingFolderPath = nil }
        }
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
            .refreshable { await reload() }
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
        ForEach(items) { item in
            switch item.kind {
            case .directory:
                #if targetEnvironment(macCatalyst)
                PlaybackRowInteraction(
                    isHighlighted: isFocused(item),
                    onSelect: { focus(on: item, transient: false) },
                    onPlay: { openFolder(at: item.path) }
                ) {
                    FolderRow(name: item.name, isOpening: openingFolderPath == item.path)
                }
                .tag(item.path)
                .overlay {
                    DoubleClickDetector(
                        onSingleClick: { focus(on: item, transient: false) },
                        onDoubleClick: { openFolder(at: item.path) }
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
                NavigationLink {
                    FolderBrowserView(source: source, path: item.path, title: item.name)
                        .environmentObject(player)
                } label: {
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
                    onPlay: { playFromQueue(startingAt: item) }
                ) {
                    TrackRow(
                        item: item,
                        isCurrent: isCurrent(item),
                        directURL: source.directURL(forPath: item.path)
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
        openFolder(at: item.path)
        return .handled
    }

    private func openFolder(at path: String) {
        ListFocusBehavior.cancelRevert(task: &focusRevertTask)
        openingFolderPath = path
        folderToOpen = FolderNavigationTarget(path: path)
    }
    #endif

    private var hasPlayableSelection: Bool {
        if let selectedItemPath,
           items.contains(where: { $0.path == selectedItemPath && $0.kind != .other }) {
            return true
        }
        return !playableTracks.isEmpty
    }

    private func playSelection() {
        if let selectedItemPath,
           let item = items.first(where: { $0.path == selectedItemPath }) {
            switch item.kind {
            case .directory:
                Task { await playFolder(at: item.path) }
            case .audio:
                playFromQueue(startingAt: item)
            case .other:
                playFolder()
            }
            return
        }
        playFolder()
    }

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

    private func playFolder() {
        guard !playableTracks.isEmpty else { return }
        let tracks = playableTracks.map { Track(sourceID: source.id, item: $0) }
        player.play(tracks: tracks, startAt: 0)
    }

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

    private func reload() async {
        isLoading = true
        loadError = nil
        do {
            items = try await source.list(path: path)
            playableTracks = try await source.audioItems(in: path, recursive: true)
        } catch {
            loadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            playableTracks = []
        }
        isLoading = false
        syncFocusFromPlayer()
    }
}

#if targetEnvironment(macCatalyst)
private struct FolderRow: View {
    let name: String
    let isOpening: Bool

    var body: some View {
        HStack {
            Label(name, systemImage: "folder")
            Spacer()
            if isOpening {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }
}
#endif

private struct TrackRow: View {
    let item: FileItem
    let isCurrent: Bool
    let directURL: URL?

    @State private var sampleRate: Double?

    var body: some View {
        HStack {
            Image(systemName: isCurrent ? "speaker.wave.2.fill" : "music.note")
                .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
                .frame(width: 24)
            VStack(alignment: .leading) {
                Text((item.name as NSString).deletingPathExtension)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(item.fileExtension.uppercased())
                    if let sampleRate {
                        Text("·")
                        Text(AudioFormatReader.formatSampleRate(sampleRate))
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if let size = item.size {
                Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .task(id: directURL?.path) {
            guard let directURL else { return }
            sampleRate = await AudioFormatReader.sampleRate(for: directURL)
        }
    }
}
