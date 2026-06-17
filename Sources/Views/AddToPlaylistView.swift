import SwiftUI

/// Sheet for adding (or removing) a single track to/from playlists. Tapping a
/// playlist toggles membership; a checkmark shows the track is already in it.
struct AddToPlaylistView: View {
    let track: Track

    @EnvironmentObject private var playlists: PlaylistManager
    @Environment(\.dismiss) private var dismiss

    @State private var showingNew = false
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        showingNew = true
                    } label: {
                        Label("New Playlist…", systemImage: "plus")
                    }
                }

                Section("Playlists") {
                    if playlists.playlists.isEmpty {
                        Text("No playlists yet")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(playlists.playlists) { playlist in
                        Button {
                            toggle(playlist)
                        } label: {
                            HStack {
                                Text(playlist.name)
                                Spacer()
                                if playlists.contains(track, in: playlist.id) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Add to Playlist")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("New Playlist", isPresented: $showingNew) {
                TextField("Name", text: $newName)
                Button("Cancel", role: .cancel) { newName = "" }
                Button("Create") {
                    let playlist = playlists.create(name: newName)
                    newName = ""
                    playlists.add(track, to: playlist.id)
                }
            } message: {
                Text("The track will be added to the new playlist.")
            }
        }
    }

    private func toggle(_ playlist: Playlist) {
        if playlists.contains(track, in: playlist.id) {
            playlists.remove(track, from: playlist.id)
        } else {
            playlists.add(track, to: playlist.id)
        }
    }
}
