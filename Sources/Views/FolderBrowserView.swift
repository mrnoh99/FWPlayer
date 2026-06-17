import SwiftUI

/// Lists the contents of one directory within a `FileSource`. Tapping a folder
/// pushes another browser; tapping an audio file plays the folder as a queue
/// starting at that file.
struct FolderBrowserView: View {
    let source: any FileSource
    let path: String
    let title: String

    @EnvironmentObject private var player: AudioPlayer

    @State private var items: [FileItem] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var trackToAdd: Track?

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
                EmptyStateView(title: "No Audio Here",
                               systemImage: "music.note",
                               message: "This folder has no playable audio files.")
            } else {
                list
            }
        }
        .navigationTitle(title)
        .task(id: path) { await reload() }
        .sheet(item: $trackToAdd) { track in
            AddToPlaylistView(track: track)
        }
    }

    private var list: some View {
        List {
            ForEach(items) { item in
                switch item.kind {
                case .directory:
                    NavigationLink {
                        FolderBrowserView(source: source, path: item.path, title: item.name)
                            .environmentObject(player)
                    } label: {
                        Label(item.name, systemImage: "folder")
                    }
                case .audio:
                    Button {
                        playFromQueue(startingAt: item)
                    } label: {
                        TrackRow(item: item, isCurrent: isCurrent(item))
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        Button {
                            trackToAdd = Track(sourceID: source.id, item: item)
                        } label: {
                            Label("Add", systemImage: "text.badge.plus")
                        }
                        .tint(.accentColor)
                    }
                    .contextMenu {
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
        .refreshable { await reload() }
    }

    private func isCurrent(_ item: FileItem) -> Bool {
        guard let current = player.currentTrack else { return false }
        return current.sourceID == source.id && current.path == item.path
    }

    private func playFromQueue(startingAt item: FileItem) {
        let tracks = audioItems.map { Track(sourceID: source.id, item: $0) }
        guard let index = audioItems.firstIndex(of: item) else { return }
        player.play(tracks: tracks, startAt: index)
    }

    private func reload() async {
        isLoading = true
        loadError = nil
        do {
            items = try await source.list(path: path)
        } catch {
            loadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        isLoading = false
    }
}

private struct TrackRow: View {
    let item: FileItem
    let isCurrent: Bool

    var body: some View {
        HStack {
            Image(systemName: isCurrent ? "speaker.wave.2.fill" : "music.note")
                .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
                .frame(width: 24)
            VStack(alignment: .leading) {
                Text((item.name as NSString).deletingPathExtension)
                    .lineLimit(1)
                Text(item.fileExtension.uppercased())
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
    }
}
