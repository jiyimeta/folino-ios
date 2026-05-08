import Domain
import SwiftUI

struct PlaylistsListView: View {
    let playlists: [Playlist]
    let onCreate: (String) -> Void

    @State private var isCreating = false
    @State private var newPlaylistName: String = ""

    var body: some View {
        Group {
            if playlists.isEmpty {
                ContentUnavailableView {
                    Label {
                        Text("No Playlists", bundle: .module)
                    } icon: {
                        Image(systemName: "music.note.list")
                    }
                } description: {
                    Text("Create a playlist with the + button above.", bundle: .module)
                }
            } else {
                List {
                    ForEach(playlists) { playlist in
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
        .navigationTitle(Text("Playlists", bundle: .module))
        .toolbar { newPlaylistToolbar }
        .alert(Text("New Playlist", bundle: .module), isPresented: $isCreating) {
            TextField(text: $newPlaylistName) { Text("Playlist name", bundle: .module) }
            Button {
                let trimmed = newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                onCreate(trimmed)
                newPlaylistName = ""
            } label: {
                Text("Add", bundle: .module)
            }
            Button(role: .cancel) {} label: { Text("Cancel", bundle: .module) }
        } message: {
            Text("Enter a name for the new playlist.", bundle: .module)
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
            Image(systemName: "plus").accessibilityLabel(Text("New Playlist", bundle: .module))
        }
    }
}

#if DEBUG
    private struct PlaylistsListViewPreviewHost: View {
        let playlists: [Playlist]
        var body: some View {
            NavigationStack {
                PlaylistsListView(playlists: playlists, onCreate: { _ in })
            }
        }
    }

    #Preview("Filled") {
        PlaylistsListViewPreviewHost(playlists: [
            Playlist(name: "Daily warm-up", orderedScoreItemIDs: [], createdAt: Date()),
            Playlist(name: "Recital set", orderedScoreItemIDs: [], createdAt: Date()),
        ])
    }

    #Preview("Empty") {
        PlaylistsListViewPreviewHost(playlists: [])
    }
#endif
