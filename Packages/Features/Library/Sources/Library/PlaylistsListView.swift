import Domain
import SwiftUI

struct PlaylistsListView: View {
    let library: LibraryViewModel

    @State private var isCreating = false
    @State private var newPlaylistName: String = ""

    var body: some View {
        Group {
            if sortedPlaylists.isEmpty {
                ContentUnavailableView {
                    Label("No Playlists", systemImage: "music.note.list")
                } description: {
                    Text("Create a playlist with the + button above.")
                }
            } else {
                List {
                    ForEach(sortedPlaylists) { playlist in
                        NavigationLink(value: LibraryRoute.playlistDetail(playlist.id)) {
                            HStack {
                                Image(systemName: "music.note.list")
                                    .foregroundStyle(.tint)
                                Text(playlist.name)
                                    .foregroundStyle(.primary)
                                Spacer()
                                Text(playlist.orderedScoreItemIDs.count, format: .number)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Playlists")
        .toolbar { newPlaylistToolbar }
        .alert("New Playlist", isPresented: $isCreating) {
            TextField("Playlist name", text: $newPlaylistName)
            Button("Add") { Task { await commit() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enter a name for the new playlist.")
        }
    }

    @ToolbarContentBuilder
    private var newPlaylistToolbar: some ToolbarContent {
        #if os(iOS)
            ToolbarItem(placement: .topBarTrailing) { newPlaylistButton }
        #else
            ToolbarItem(placement: .automatic) { newPlaylistButton }
        #endif
    }

    private var newPlaylistButton: some View {
        Button {
            newPlaylistName = ""
            isCreating = true
        } label: {
            Image(systemName: "plus").accessibilityLabel("New Playlist")
        }
    }

    private var sortedPlaylists: [Playlist] {
        library.repository.playlists.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func commit() async {
        let trimmed = newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let playlist = Playlist(name: trimmed, orderedScoreItemIDs: [], createdAt: Date())
        do {
            try await library.repository.savePlaylist(playlist)
        } catch {
            library.errorAlertMessage = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }
}
