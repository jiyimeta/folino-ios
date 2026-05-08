import Domain
import SwiftUI

struct PlaylistDetailScreen: View {
    let playlist: Playlist
    let library: LibraryViewModel
    let onOpen: (ScoreItem) -> Void
    let onPlaylistDeleted: () -> Void

    var body: some View {
        PlaylistDetailView(
            playlistName: playlist.name,
            items: orderedItems,
            onOpen: onOpen,
            onMove: { offsets, destination in move(from: offsets, to: destination) },
            onRemoveFromPlaylist: { offsets in removeFromPlaylist(at: offsets) },
            onRename: { newName in Task { await commitRename(newName) } },
            onDelete: { Task { await commitDelete() } }
        )
    }

    private var orderedItems: [ScoreItem] {
        let lookup = Dictionary(uniqueKeysWithValues: library.repository.scoreItems.map { ($0.id, $0) })
        return playlist.orderedScoreItemIDs.compactMap { lookup[$0] }
    }

    private func move(from offsets: IndexSet, to destination: Int) {
        var ids = playlist.orderedScoreItemIDs
        ids.move(fromOffsets: offsets, toOffset: destination)
        var updated = playlist
        updated.orderedScoreItemIDs = ids
        Task { await save(updated) }
    }

    private func removeFromPlaylist(at offsets: IndexSet) {
        let removedIDs = offsets.map { orderedItems[$0].id }
        var updated = playlist
        updated.orderedScoreItemIDs.removeAll { removedIDs.contains($0) }
        Task { await save(updated) }
    }

    private func commitRename(_ newName: String) async {
        var updated = playlist
        updated.name = newName
        await save(updated)
    }

    private func commitDelete() async {
        do {
            try await library.repository.deletePlaylist(id: playlist.id)
            onPlaylistDeleted()
        } catch {
            library.errorAlertMessage = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    private func save(_ updated: Playlist) async {
        do {
            try await library.repository.savePlaylist(updated)
        } catch {
            library.errorAlertMessage = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }
}
