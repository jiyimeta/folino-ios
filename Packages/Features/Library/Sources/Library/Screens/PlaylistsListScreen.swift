import Domain
import SwiftUI

struct PlaylistsListScreen: View {
    let library: LibraryViewModel

    var body: some View {
        PlaylistsListView(
            playlists: sortedPlaylists,
            memberCount: { playlist in
                PlaylistPresentation.liveMemberCount(playlist, liveIDs: liveIDs)
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
