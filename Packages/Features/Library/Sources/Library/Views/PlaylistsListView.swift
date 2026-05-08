import Domain
import SwiftUI
import UtilityUI

struct PlaylistsListView: View {
    let playlists: [Playlist]
    let onCreate: (String) -> Void

    var body: some View {
        Group {
            if playlists.isEmpty {
                ContentUnavailableView {
                    Label {
                        Text("library.playlists.empty.title", bundle: .module)
                    } icon: {
                        Image(systemName: "music.note.list")
                    }
                } description: {
                    Text("library.playlists.empty.hint", bundle: .module)
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
        .navigationTitle(Text("library.playlists", bundle: .module))
        .createEntityToolbar(copy: .playlist, onCreate: onCreate)
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
