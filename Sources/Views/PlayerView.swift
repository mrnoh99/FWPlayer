import SwiftUI

/// Full-screen player. On a wide screen (iPad / Mac Catalyst) it splits into the
/// Apple Music landscape layout: artwork + transport on the left, the Up Next
/// queue on the right. On iPhone it stays a single column and the queue is
/// reached from the toolbar. A route button lets the user pick where audio plays.
struct PlayerView: View {
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var artwork: ArtworkStore
    @EnvironmentObject private var playlists: PlaylistManager
    @Environment(\.dismiss) private var dismiss
    var onShowQueue: (() -> Void)? = nil

    @State private var isLoading = false
    @State private var title = "Not Playing"
    @State private var artist: String?
    @State private var album: String?
    @State private var year: String?
    @State private var genre: String?
    @State private var sampleRate: Double?
    @State private var isPlaying = false
    @State private var currentTime: TimeInterval = 0
    @State private var duration: TimeInterval = 0
    @State private var canGoPrevious = false
    @State private var canGoNext = false
    @State private var isShuffled = false
    @State private var repeatMode: RepeatMode = .off

    /// Local scrub position while the user is dragging the slider.
    @State private var scrubTime: Double = 0
    @State private var isScrubbing = false
    @State private var trackToAdd: Track?
    /// True when there's room for the two-pane (artwork + Up Next) layout. Based
    /// on actual width, since an iPad sheet reports a compact size class.
    @State private var isWide = false
    /// Whether the Apple Music Catalog details panel is expanded.
    @State private var detailsExpanded = false

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                Capsule()
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 40, height: 5)
                    .padding(.top, 8)

                if isWide {
                    HStack(alignment: .top, spacing: 24) {
                        nowPlayingColumn
                            .frame(width: 340)
                        Divider()
                        queueColumn
                            .frame(maxWidth: .infinity)
                    }
                    .padding()
                } else {
                    nowPlayingColumn
                        .padding()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear { isWide = geo.size.width > 680 }
            .onChange(of: geo.size.width) { _, width in isWide = width > 680 }
        }
        // An always-present close control: Mac Catalyst sheets don't swipe to
        // dismiss and show no drag indicator, so without this the full player
        // can't be closed. Esc / ⌘W also dismiss it.
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .padding(12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Close")
        }
        .presentationDragIndicator(.hidden)
        .toolbar {
            if !isWide, let onShowQueue, !player.queue.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        dismiss()
                        onShowQueue()
                    } label: {
                        Label("Queue", systemImage: "list.bullet")
                    }
                }
            }
        }
        .sheet(item: $trackToAdd) { track in
            AddToPlaylistView(track: track)
        }
        .onAppear { refreshFromPlayer() }
        .onReceive(player.objectWillChange) { _ in
            Task { @MainActor in refreshFromPlayer() }
        }
    }

    // MARK: - Now Playing (left)

    private var nowPlayingColumn: some View {
        ScrollView {
            VStack(spacing: 18) {
                artworkView
                infoRow
                scrubber
                transportControls
                outputRow
                catalogSummary
                catalogDetails
            }
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
            .padding(.bottom, 12)
        }
    }

    // MARK: - Apple Music Catalog details

    /// The core catalog fields, shown directly on the detail screen.
    @ViewBuilder
    private var catalogSummary: some View {
        if let info = player.currentCatalogInfo, info.hasDisplayableDetails {
            VStack(alignment: .leading, spacing: 6) {
                detailRow("Album", info.albumTitle)
                detailRow("Artist", info.artistName)
                detailRow("Genre", info.genres.isEmpty ? nil : info.genres.joined(separator: ", "))
                detailRow("Released", releasedText(info))
                detailRow("Tracks", info.trackCount.map { String($0) })
                detailRow("Label", info.recordLabel)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.horizontal, 4)
        }
    }

    /// The longer fields (rating, copyright, description, lyrics), tucked into a
    /// collapsible panel so they don't crowd the screen.
    @ViewBuilder
    private var catalogDetails: some View {
        if let info = player.currentCatalogInfo, Self.hasExtended(info) {
            DisclosureGroup(isExpanded: $detailsExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    detailRow("Rating", info.contentRating)
                    detailRow("Copyright", info.copyright)
                    detailParagraph("About", info.editorialNotes)
                    detailParagraph("Lyrics", info.lyrics)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
            } label: {
                Label("More Info", systemImage: "info.circle")
                    .font(.subheadline.weight(.semibold))
            }
            .tint(.secondary)
            .padding(.horizontal, 4)
        }
    }

    /// Whether the collapsible panel has anything beyond the always-shown summary.
    private static func hasExtended(_ info: MusicKitCatalog.AlbumInfo) -> Bool {
        info.contentRating != nil || info.copyright != nil
            || info.editorialNotes != nil || info.lyrics != nil
    }

    @ViewBuilder
    private func detailRow(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 78, alignment: .leading)
                Text(value)
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func detailParagraph(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func releasedText(_ info: MusicKitCatalog.AlbumInfo) -> String? {
        if let date = info.releaseDate {
            return Self.releaseDateFormatter.string(from: date)
        }
        return info.year
    }

    private static let releaseDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    private var artworkView: some View {
        Group {
            if let cover = player.currentTrack.flatMap({ artwork.image(for: $0) }) {
                Image(uiImage: cover).resizable().scaledToFill()
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 90))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.secondary.opacity(0.12))
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: 300, maxHeight: 300)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .shadow(color: .black.opacity(0.2), radius: 12, y: 6)
    }

    private var infoRow: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                if isLoading {
                    ProgressView()
                } else {
                    Text(title)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                }
                Text(subtitleText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                // Shown only when the fuller catalog summary isn't (it would repeat
                // the album/year/genre otherwise).
                if player.currentCatalogInfo == nil, let albumYear = albumYearText {
                    Text(albumYear)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)

            if let track = player.currentTrack {
                Button {
                    playlists.toggleFavorite(track)
                } label: {
                    Image(systemName: playlists.isFavorite(track) ? "star.fill" : "star")
                        .font(.title3)
                        .foregroundStyle(playlists.isFavorite(track) ? Color.yellow : Color.secondary)
                }
                .buttonStyle(.plain)

                Menu {
                    Button {
                        trackToAdd = track
                    } label: {
                        Label("Add to Playlist", systemImage: "text.badge.plus")
                    }
                    Button(role: playlists.isFavorite(track) ? .destructive : nil) {
                        playlists.toggleFavorite(track)
                    } label: {
                        Label(playlists.isFavorite(track) ? "Remove from Favorites" : "Add to Favorites",
                              systemImage: playlists.isFavorite(track) ? "star.slash" : "star")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 4)
    }

    private var subtitleText: String {
        var parts: [String] = []
        if let artist { parts.append(artist) }
        if let sampleRate { parts.append(AudioFormatReader.formatSampleRate(sampleRate)) }
        return parts.joined(separator: " · ")
    }

    /// Album title, release year, and genre, shown small below the title when
    /// known (year/genre may come from the Apple Music Catalog).
    private var albumYearText: String? {
        let parts = [album, year, genre].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var scrubberMax: Double {
        max(duration.isFinite ? duration : 0, 0.1)
    }

    private var displayedTime: Double {
        let time = isScrubbing ? scrubTime : currentTime
        guard time.isFinite else { return 0 }
        return min(max(time, 0), scrubberMax)
    }

    /// A knob-less progress bar (just a track + fill) that's still draggable to
    /// seek, matching the floating bar / Apple Music style.
    private var scrubber: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                let width = geo.size.width
                let progress = scrubberMax > 0 ? CGFloat(displayedTime / scrubberMax) : 0
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.25))
                    Capsule().fill(Color.accentColor)
                        .frame(width: max(0, min(progress, 1)) * width)
                }
                .frame(height: 5)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            isScrubbing = true
                            let ratio = max(0, min(value.location.x / max(width, 1), 1))
                            scrubTime = Double(ratio) * scrubberMax
                        }
                        .onEnded { _ in
                            let target = scrubTime
                            isScrubbing = false
                            Task { @MainActor in player.seek(to: target) }
                        }
                )
            }
            .frame(height: 16)
            HStack {
                Text(timeString(displayedTime))
                Spacer()
                Text(timeString(duration))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    /// Shuffle · prev · play · next · repeat, matching Apple Music's transport row.
    private var transportControls: some View {
        HStack(spacing: 0) {
            Button {
                Haptics.tap()
                Task { @MainActor in player.toggleShuffle() }
            } label: {
                Image(systemName: "shuffle")
                    .font(.title3)
                    .foregroundStyle(isShuffled ? Color.accentColor : .secondary)
            }

            Spacer()

            HStack(spacing: 36) {
                Button {
                    Haptics.tap()
                    Task { @MainActor in player.previous() }
                } label: {
                    Image(systemName: "backward.fill").font(.title)
                }
                .disabled(!canGoPrevious)

                if isLoading {
                    // Preparing the track — show a spinner so the press is visible.
                    ProgressView()
                        .controlSize(.large)
                        .frame(width: 60, height: 60)
                } else {
                    Button {
                        Haptics.tap()
                        Task { @MainActor in player.togglePlayPause() }
                    } label: {
                        Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 60))
                    }
                }

                Button {
                    Haptics.tap()
                    Task { @MainActor in player.next() }
                } label: {
                    Image(systemName: "forward.fill").font(.title)
                }
                .disabled(!canGoNext)
            }

            Spacer()

            Button {
                Haptics.tap()
                Task { @MainActor in player.cycleRepeatMode() }
            } label: {
                Image(systemName: repeatMode == .one ? "repeat.1" : "repeat")
                    .font(.title3)
                    .foregroundStyle(repeatMode == .off ? .secondary : Color.accentColor)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
    }

    /// Output-route (AirPlay) button — choose where sound is sent.
    private var outputRow: some View {
        HStack {
            AudioRoutePickerButton()
                .frame(width: 42, height: 42)
            Text("Output")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Up Next (right)

    /// Upcoming queue entries paired with their absolute index in the queue.
    private var upcoming: [(offset: Int, element: Track)] {
        let all = Array(player.queue.enumerated())
        guard let current = player.currentIndex else { return all.map { ($0.offset, $0.element) } }
        return all.filter { $0.offset > current }.map { ($0.offset, $0.element) }
    }

    private var queueColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Up Next")
                    .font(.headline)
                Spacer()
                Menu {
                    Button(role: .destructive) {
                        let indices = upcoming.map { $0.offset }
                        Task { @MainActor in player.removeFromQueue(at: IndexSet(indices)) }
                    } label: {
                        Label("Clear Up Next", systemImage: "trash")
                    }
                    .disabled(upcoming.isEmpty)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 4)

            if upcoming.isEmpty {
                VStack {
                    Spacer()
                    Text("No upcoming tracks")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(upcoming, id: \.offset) { item in
                        HStack(spacing: 6) {
                            Button {
                                Task { @MainActor in player.play(at: item.offset) }
                            } label: {
                                queueRow(item.element)
                            }
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity, alignment: .leading)

                            upcomingRowMenu(item)
                        }
                        .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                    }
                    .onMove { source, destination in
                        moveUpcoming(from: source, to: destination)
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    private func queueRow(_ track: Track) -> some View {
        HStack(spacing: 10) {
            queueArtwork(track)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).lineLimit(1)
                if let line = track.artist ?? track.album {
                    Text(line).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    /// Per-track actions for an upcoming queue entry (kept outside the play-tap
    /// area so it always opens).
    private func upcomingRowMenu(_ item: (offset: Int, element: Track)) -> some View {
        let track = item.element
        return Menu {
            Button {
                Task { @MainActor in player.play(at: item.offset) }
            } label: {
                Label("Play Now", systemImage: "play.fill")
            }
            Button { trackToAdd = track } label: {
                Label("Add to Playlist", systemImage: "text.badge.plus")
            }
            Button(role: playlists.isFavorite(track) ? .destructive : nil) {
                playlists.toggleFavorite(track)
            } label: {
                Label(playlists.isFavorite(track) ? "Remove from Favorites" : "Add to Favorites",
                      systemImage: playlists.isFavorite(track) ? "star.slash" : "star")
            }
            Divider()
            Button(role: .destructive) {
                Task { @MainActor in player.removeFromQueue(at: IndexSet(integer: item.offset)) }
            } label: {
                Label("Remove from Queue", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func queueArtwork(_ track: Track) -> some View {
        Group {
            if let img = artwork.image(for: track) {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                Image(systemName: "music.note")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.secondary.opacity(0.12))
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    /// Maps a move within the upcoming sublist back to absolute queue indices.
    private func moveUpcoming(from source: IndexSet, to destination: Int) {
        let base = (player.currentIndex ?? -1) + 1
        let absoluteSource = IndexSet(source.map { $0 + base })
        let absoluteDestination = destination + base
        Task { @MainActor in
            player.moveQueue(fromOffsets: absoluteSource, toOffset: absoluteDestination)
        }
    }

    // MARK: - State

    private func refreshFromPlayer() {
        isLoading = player.isLoading
        title = player.currentTrack?.title ?? "Not Playing"
        artist = player.currentTrack?.artist
        album = player.currentTrack?.album
        year = player.currentTrack?.year
        genre = player.currentTrack?.genre
        sampleRate = player.currentTrack?.sampleRate
        isPlaying = player.isPlaying
        currentTime = player.currentTime
        duration = player.duration
        canGoPrevious = player.canGoPrevious
        canGoNext = player.canGoNext
        isShuffled = player.isShuffled
        repeatMode = player.repeatMode
    }

    private func timeString(_ time: TimeInterval) -> String {
        guard time.isFinite, time >= 0 else { return "0:00" }
        let total = Int(time)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
