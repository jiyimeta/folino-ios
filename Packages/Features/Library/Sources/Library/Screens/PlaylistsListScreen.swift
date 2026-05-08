import Domain
import SwiftUI

struct PlaylistsListScreen: View {
    let library: LibraryViewModel

    var body: some View {
        PlaylistsListView(
            playlists: sortedPlaylists,
            onCreate: { name in
                Task { await library.createPlaylist(name: name) }
            }
        )
    }

    private var sortedPlaylists: [Playlist] {
        library.repository.playlists.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}
