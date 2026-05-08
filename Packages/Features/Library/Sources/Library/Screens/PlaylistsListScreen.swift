import Domain
import SwiftUI

struct PlaylistsListScreen: View {
    let library: LibraryViewModel

    var body: some View {
        PlaylistsListView(
            playlists: sortedPlaylists,
            onCreate: { name in
                let playlist = Playlist(name: name, orderedScoreItemIDs: [], createdAt: Date())
                Task {
                    do {
                        try await library.repository.savePlaylist(playlist)
                    } catch {
                        library.errorAlertMessage = (error as? LocalizedError)?.errorDescription
                            ?? error.localizedDescription
                    }
                }
            }
        )
    }

    private var sortedPlaylists: [Playlist] {
        library.repository.playlists.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}
