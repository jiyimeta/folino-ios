import Domain
import Foundation
import SwiftUI

struct PlaylistDetailScreen: View {
    let playlist: Playlist
    let library: LibraryViewModel
    let onOpen: (ScoreItem) -> Void
    let onPlaylistDeleted: () -> Void

    @State private var selectedIDs: Set<ScoreItemID> = []
    @State private var bulkSheet: BulkSheet?
    @State private var bulkDeletePrompt: BulkDeletePrompt?

    private enum BulkSheet: Identifiable {
        case addToPlaylist
        case editTags
        var id: Int {
            switch self {
            case .addToPlaylist: 0
            case .editTags: 1
            }
        }
    }

    private struct BulkDeletePrompt: Identifiable {
        let id = UUID()
        let count: Int
    }

    var body: some View {
        PlaylistDetailView(
            playlistName: playlist.name,
            items: orderedItems,
            onOpen: onOpen,
            onMove: { offsets, destination in move(from: offsets, to: destination) },
            onRemoveFromPlaylist: { offsets in removeFromPlaylist(at: offsets) },
            onRename: { newName in Task { await commitRename(newName) } },
            onDelete: { Task { await commitDelete() } },
            selectedIDs: $selectedIDs,
            availableShareFormats: bulkAvailableShareFormats,
            onBulkShare: { format in performBulkShare(format) },
            onBulkAddToPlaylist: { bulkSheet = .addToPlaylist },
            onBulkEditTags: { bulkSheet = .editTags },
            onBulkDelete: { bulkDeletePrompt = BulkDeletePrompt(count: selectedIDs.count) }
        )
        .sheet(item: $bulkSheet) { which in
            switch which {
            case .addToPlaylist:
                BulkAddToPlaylistScreen(
                    selectedIDs: selectedIDs,
                    orderedSelectedIDs: orderedSelectedIDs,
                    library: library,
                    onCommit: { selectedIDs = []; bulkSheet = nil }
                )
            case .editTags:
                BulkEditTagsScreen(
                    selectedIDs: selectedIDs,
                    library: library,
                    onCommit: { selectedIDs = []; bulkSheet = nil }
                )
            }
        }
        .confirmationDialog(
            Text("Delete \(bulkDeletePrompt?.count ?? 0) scores?", bundle: .module),
            isPresented: bulkDeleteAlertBinding,
            presenting: bulkDeletePrompt
        ) { _ in
            Button {
                let ids = selectedIDs
                Task {
                    await library.bulkRemoveFromPlaylist(ids, from: currentPlaylist())
                    selectedIDs = []
                }
            } label: {
                Text("Remove from playlist", bundle: .module)
            }
            Button(role: .destructive) {
                let ids = selectedIDs
                Task {
                    await library.bulkDelete(ids)
                    selectedIDs = []
                }
            } label: {
                Text("Delete completely", bundle: .module)
            }
            Button(role: .cancel) {} label: { Text("Cancel", bundle: .module) }
        }
    }

    private var orderedItems: [ScoreItem] {
        let lookup = Dictionary(uniqueKeysWithValues: library.repository.scoreItems.map { ($0.id, $0) })
        return currentPlaylist().orderedScoreItemIDs.compactMap { lookup[$0] }
    }

    private var orderedSelectedIDs: [ScoreItemID] {
        orderedItems.map(\.id).filter { selectedIDs.contains($0) }
    }

    private var selectedItems: [ScoreItem] {
        orderedItems.filter { selectedIDs.contains($0.id) }
    }

    private var bulkAvailableShareFormats: [ScoreShareFormat] {
        let perItem = selectedItems.map { Set(library.shareService.availableFormats(for: $0)) }
        guard let first = perItem.first else { return [] }
        let intersection = perItem.dropFirst().reduce(first) { $0.intersection($1) }
        return [.sourceFormat, .pdf, .midi].filter { intersection.contains($0) }
    }

    private func performBulkShare(_ format: ScoreShareFormat) {
        // TODO: proper multi-URL bulk share. For now, share the first
        // selected item — system share sheet handles one URL.
        guard let first = selectedItems.first else { return }
        Task { await library.requestShare(first, format: format) }
    }

    private var bulkDeleteAlertBinding: Binding<Bool> {
        Binding(
            get: { bulkDeletePrompt != nil },
            set: { isPresented in if !isPresented { bulkDeletePrompt = nil } }
        )
    }

    /// Re-read the playlist on each touch so reorder/save round-trips work.
    private func currentPlaylist() -> Playlist {
        library.repository.playlists.first(where: { $0.id == playlist.id }) ?? playlist
    }

    private func move(from offsets: IndexSet, to destination: Int) {
        var ids = currentPlaylist().orderedScoreItemIDs
        ids.move(fromOffsets: offsets, toOffset: destination)
        var updated = currentPlaylist()
        updated.orderedScoreItemIDs = ids
        Task { await save(updated) }
    }

    private func removeFromPlaylist(at offsets: IndexSet) {
        let removedIDs = offsets.map { orderedItems[$0].id }
        var updated = currentPlaylist()
        updated.orderedScoreItemIDs.removeAll { removedIDs.contains($0) }
        Task { await save(updated) }
    }

    private func commitRename(_ newName: String) async {
        var updated = currentPlaylist()
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
