import Domain
import Foundation
import SwiftUI
import UtilityCore
import UtilityUI

struct PlaylistDetailScreen: View {
    let playlist: Playlist
    let library: LibraryViewModel
    /// Opens a score while recording that it came from this playlist, so the Reader can traverse the playlist.
    let onOpenInPlaylist: (ScoreItem, PlaylistID) -> Void
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
            onOpen: openScore,
            // `openScore` routes through `onOpenInPlaylist`, the screen's only open channel, which carries the
            // `PlaylistID`. On the Mac that closure ends in `openWindow(value:)`, so a row here does open a window —
            // see the `PARITY(macos)` marker on `MacLibraryWindowContent`'s `onOpenInPlaylist` for what is still
            // missing (the playlist id is dropped at the window boundary).
            onMove: { offsets, destination in move(from: offsets, to: destination) },
            onRemoveFromPlaylist: { item in removeFromPlaylist(item) },
            onRename: { newName in Task { await commitRename(newName) } },
            onDelete: { Task { await commitDelete() } },
            selectedIDs: $selectedIDs,
            availableShareFormats: bulkAvailableShareFormats,
            onBulkShare: { format in performBulkShare(format) },
            onBulkAddToPlaylist: { bulkSheet = .addToPlaylist },
            onBulkEditTags: { bulkSheet = .editTags },
            onBulkFavorite: {
                let ids = selectedIDs
                let makeFavorite = !allSelectedFavorited
                Task {
                    await library.bulkSetFavorite(ids, favorite: makeFavorite)
                    selectedIDs = []
                }
            },
            allBulkFavorited: allSelectedFavorited,
            onBulkDelete: { bulkDeletePrompt = BulkDeletePrompt(count: selectedIDs.count) },
        )
        .sheet(item: $bulkSheet) { which in
            switch which {
            case .addToPlaylist:
                BulkAddToPlaylistScreen(
                    selectedIDs: selectedIDs,
                    orderedSelectedIDs: orderedSelectedIDs,
                    library: library,
                    onCommit: { selectedIDs = []; bulkSheet = nil },
                )
            case .editTags:
                BulkEditTagsScreen(
                    selectedIDs: selectedIDs,
                    library: library,
                    onCommit: { selectedIDs = []; bulkSheet = nil },
                )
            }
        }
        .confirmationDialog(
            Text(String(
                localized: "library.score.deleteBulk.title",
                defaultValue: "Delete \(bulkDeletePrompt?.count ?? 0) scores?",
                bundle: .module,
            )),
            isPresented: bulkDeleteAlertBinding,
            presenting: bulkDeletePrompt,
        ) { _ in
            Button {
                let ids = selectedIDs
                Task {
                    await library.bulkRemoveFromPlaylist(ids, from: currentPlaylist())
                    selectedIDs = []
                }
            } label: {
                Text("library.playlist.removeScore.action", bundle: .module)
            }
            Button(role: .destructive) {
                let ids = selectedIDs
                Task {
                    await library.bulkDelete(ids)
                    selectedIDs = []
                }
            } label: {
                Text("library.playlist.deleteScoreCompletely.action", bundle: .module)
            }
            Button(role: .cancel) {} label: { L10n.Common.cancel }
        }
        .onAppear { library.analytics.logScreen(.playlistDetail) }
    }

    /// Log `select_content` attributed to this playlist, then hand the item to the reader-traversal callback. The
    /// source `onOpen` passes to `PlaylistDetailView` — see that call's comment.
    private func openScore(_ item: ScoreItem) {
        library.analytics.log(.scoreOpened(from: .playlist))
        onOpenInPlaylist(item, playlist.id)
    }

    private var orderedItems: [ScoreItem] {
        let lookup = Dictionary(uniqueKeysWithValues: library.repository.scoreItems.map { ($0.id, $0) })
        return PlaylistPresentation
            .orderedLiveIDs(currentPlaylist(), liveIDs: Set(lookup.keys))
            .compactMap { lookup[$0] }
    }

    private var orderedSelectedIDs: [ScoreItemID] {
        orderedItems.map(\.id).filter { selectedIDs.contains($0) }
    }

    private var selectedItems: [ScoreItem] {
        orderedItems.filter { selectedIDs.contains($0.id) }
    }

    private var allSelectedFavorited: Bool {
        let items = selectedItems
        return !items.isEmpty && items.allSatisfy(\.isFavorite)
    }

    private var bulkAvailableShareFormats: [ScoreShareFormat] {
        // See `ScoreListScreen.bulkAvailableShareFormats` for the per-item-vs-bulk reasoning.
        selectedItems.isEmpty ? [] : [.museScoreV4, .museScoreV3, .pdf, .midi]
    }

    private func performBulkShare(_ format: ScoreShareFormat) {
        let items = selectedItems
        Task { await library.requestBulkShare(items, format: format) }
    }

    private var bulkDeleteAlertBinding: Binding<Bool> {
        Binding(
            get: { bulkDeletePrompt != nil },
            set: { isPresented in
                if !isPresented {
                    bulkDeletePrompt = nil
                }
            },
        )
    }

    /// Re-read the playlist on each touch so reorder/save round-trips work.
    private func currentPlaylist() -> Playlist {
        library.repository.playlists.first(where: { $0.id == playlist.id }) ?? playlist
    }

    private func move(from offsets: IndexSet, to destination: Int) {
        let current = currentPlaylist()
        var ids = current.orderedScoreItemIDs
        ids.move(fromOffsets: offsets, toOffset: destination)
        guard ids != current.orderedScoreItemIDs else { return }
        var updated = current
        updated.orderedScoreItemIDs = ids
        Task {
            if await save(updated) {
                library.analytics.log(.playlistReordered())
            }
        }
    }

    private func removeFromPlaylist(_ item: ScoreItem) {
        var updated = currentPlaylist()
        updated.remove([item.id])
        Task {
            if await save(updated) {
                library.analytics.log(.scoreRemovedFromPlaylist(source: .playlist, count: 1))
            }
        }
    }

    private func commitRename(_ newName: String) async {
        var updated = currentPlaylist()
        updated.name = newName
        if await save(updated) {
            library.analytics.log(.playlistRenamed(source: .playlist))
        }
    }

    private func commitDelete() async {
        do {
            try await library.repository.deletePlaylist(id: playlist.id)
            library.analytics.log(.playlistDeleted(source: .playlist))
            onPlaylistDeleted()
        } catch {
            library.currentError = error
        }
    }

    /// Persist `updated`; returns `true` on success so callers log the matching analytics event only when the write
    /// actually landed.
    @discardableResult
    private func save(_ updated: Playlist) async -> Bool {
        do {
            try await library.repository.savePlaylist(updated)
            return true
        } catch {
            library.currentError = error
            return false
        }
    }
}
