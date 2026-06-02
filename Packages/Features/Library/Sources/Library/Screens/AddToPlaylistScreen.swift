import Domain
import SwiftUI

struct AddToPlaylistScreen: View {
    let scoreItem: ScoreItem
    let library: LibraryViewModel

    var body: some View {
        AddToPlaylistSheet(
            scoreTitle: scoreItem.title,
            scoreItemID: scoreItem.id,
            allPlaylists: library.repository.playlists,
            onToggle: { playlist in Task { await toggle(playlist) } },
            onCreate: { name in Task { await commitNewPlaylist(name) } },
        )
    }

    private func toggle(_ playlist: Playlist) async {
        var updated = playlist
        updated.toggleMembership(scoreItem.id)
        do {
            try await library.repository.savePlaylist(updated)
        } catch {
            library.currentError = error
        }
    }

    private func commitNewPlaylist(_ name: String) async {
        let playlist = Playlist(
            name: name,
            orderedScoreItemIDs: [scoreItem.id],
            createdAt: Date(),
        )
        do {
            try await library.repository.savePlaylist(playlist)
        } catch {
            library.currentError = error
        }
    }
}
