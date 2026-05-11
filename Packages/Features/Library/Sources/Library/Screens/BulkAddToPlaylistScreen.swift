import Domain
import SwiftUI

struct BulkAddToPlaylistScreen: View {
    let selectedIDs: Set<ScoreItemID>
    let orderedSelectedIDs: [ScoreItemID]
    let library: LibraryViewModel
    let onCommit: () -> Void

    var body: some View {
        BulkAddToPlaylistSheet(
            selectionCount: selectedIDs.count,
            selectedIDs: selectedIDs,
            allPlaylists: library.repository.playlists,
            onPick: { playlist in Task { await commitPick(playlist) } },
            onCreate: { name in Task { await commitCreate(name) } },
        )
    }

    private func commitPick(_ playlist: Playlist) async {
        await library.bulkAddToPlaylist(orderedSelectedIDs, to: playlist)
        onCommit()
    }

    private func commitCreate(_ name: String) async {
        let playlist = Playlist(
            name: name,
            orderedScoreItemIDs: orderedSelectedIDs,
            createdAt: Date(),
        )
        do {
            try await library.repository.savePlaylist(playlist)
        } catch {
            library.errorAlertMessage = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            return
        }
        onCommit()
    }
}
