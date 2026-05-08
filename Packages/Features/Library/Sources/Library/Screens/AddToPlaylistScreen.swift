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
            onCreate: { name in Task { await commitNewPlaylist(name) } }
        )
    }

    private func toggle(_ playlist: Playlist) async {
        var updated = playlist
        if let idx = updated.orderedScoreItemIDs.firstIndex(of: scoreItem.id) {
            updated.orderedScoreItemIDs.remove(at: idx)
        } else {
            updated.orderedScoreItemIDs.append(scoreItem.id)
        }
        do {
            try await library.repository.savePlaylist(updated)
        } catch {
            library.errorAlertMessage = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    private func commitNewPlaylist(_ name: String) async {
        let playlist = Playlist(
            name: name,
            orderedScoreItemIDs: [scoreItem.id],
            createdAt: Date()
        )
        do {
            try await library.repository.savePlaylist(playlist)
        } catch {
            library.errorAlertMessage = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }
}
