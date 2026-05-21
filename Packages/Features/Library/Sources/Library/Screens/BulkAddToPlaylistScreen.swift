import Domain
import LibraryLogic
import SwiftUI

struct BulkAddToPlaylistScreen: View {
    let selectedIDs: Set<ScoreItemID>
    let orderedSelectedIDs: [ScoreItemID]
    let library: LibraryStore
    let onCommit: () -> Void

    var body: some View {
        BulkAddToPlaylistSheet(
            selectionCount: selectedIDs.count,
            selectedIDs: selectedIDs,
            allPlaylists: library.playlists,
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
        await library.savePlaylist(playlist)
        guard library.playlists.contains(where: { $0.id == playlist.id }) else { return }
        onCommit()
    }
}
