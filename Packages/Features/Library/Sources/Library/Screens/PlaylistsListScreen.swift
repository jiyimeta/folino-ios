import Domain
import LibraryLogic
import SwiftUI

struct PlaylistsListScreen: View {
    let library: LibraryStore

    var body: some View {
        PlaylistsListView(
            playlists: sortedPlaylists,
            memberCount: { playlist in
                playlist.orderedScoreItemIDs.reduce(0) { acc, id in
                    acc + (liveIDs.contains(id) ? 1 : 0)
                }
            },
            onCreate: { name in
                Task { await library.createPlaylist(name: name) }
            },
            onDelete: { playlist in
                Task { await library.deletePlaylist(playlist) }
            },
        )
    }

    private var sortedPlaylists: [Playlist] {
        library.repository.playlists.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private var liveIDs: Set<ScoreItemID> {
        Set(library.repository.scoreItems.map(\.id))
    }
}
