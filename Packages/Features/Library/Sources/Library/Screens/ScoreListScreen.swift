import Domain
import SwiftUI
import UtilityCore
import UtilityUI

struct ScoreListScreen: View {
    @Bindable var viewModel: ScoreListViewModel
    let library: LibraryViewModel
    let onOpen: (ScoreItem) -> Void
    /// **macOS only**, in effect — see `ScoreListView.onOpenInNewWindow`. Every caller passes the same closure it
    /// passes to `onOpen`, since there is no separate window to open yet; a later task gives this its own meaning.
    let onOpenInNewWindow: (ScoreItem) -> Void
    let onEditTags: (ScoreItem) -> Void
    let onAddToPlaylist: (ScoreItem) -> Void

    @State private var editInfoTarget: ScoreItem?
    @State private var isSelecting = false
    @State private var selectedIDs: Set<ScoreItemID> = []
    @State private var bulkSheet: BulkSheet?

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

    var body: some View {
        listContent
            .onChange(of: viewModel.searchQuery) { oldValue, newValue in
                // Log one `search` per session: the empty -> non-empty edge marks the user starting a new search.
                if oldValue.isEmpty, !newValue.isEmpty {
                    library.analytics.log(.search())
                }
            }
            .editScoreInfoSheet(viewModel: library, target: $editInfoTarget)
            .sheet(item: $bulkSheet) { which in
                switch which {
                case .addToPlaylist:
                    BulkAddToPlaylistScreen(
                        selectedIDs: selectedIDs,
                        orderedSelectedIDs: orderedSelectedIDs,
                        library: library,
                        onCommit: { exitSelectionMode(); bulkSheet = nil },
                    )
                case .editTags:
                    BulkEditTagsScreen(
                        selectedIDs: selectedIDs,
                        library: library,
                        onCommit: { exitSelectionMode(); bulkSheet = nil },
                    )
                }
            }
    }

    private var listContent: some View {
        ScoreListView(
            items: viewModel.displayedItems,
            searchText: $viewModel.searchQuery,
            sort: viewModel.sort,
            isManualOrderActive: viewModel.isManualOrderActive,
            showsManualOrderOption: isPlaylistSource,
            onTap: openScore,
            onOpenInNewWindow: onOpenInNewWindow,
            onToggleFavorite: { item in Task { await library.toggleFavorite(item) } },
            onConfirmDelete: { item in Task { await library.delete(item) } },
            onSelectSort: { viewModel.selectSort($0) },
            onSelectManualOrder: { viewModel.selectManualOrder() },
            isSelecting: $isSelecting,
            selectedIDs: $selectedIDs,
            bulkContext: bulkContext,
            availableShareFormats: bulkAvailableShareFormats,
            onBulkShare: { format in performBulkShare(format) },
            onBulkAddToPlaylist: { bulkSheet = .addToPlaylist },
            onBulkEditTags: { bulkSheet = .editTags },
            onBulkFavorite: {
                let ids = selectedIDs
                let makeFavorite = !allSelectedFavorited
                Task {
                    await library.bulkSetFavorite(ids, favorite: makeFavorite)
                    exitSelectionMode()
                }
            },
            allSelectedFavorited: allSelectedFavorited,
            onBulkDelete: {
                let ids = selectedIDs
                Task {
                    await library.bulkDelete(ids)
                    exitSelectionMode()
                }
            },
        ) { item in
            scoreRowMenu(
                item: item,
                library: library,
                onOpen: openScore,
                onEditInfo: { item in editInfoTarget = item },
                onEditTags: onEditTags,
                onAddToPlaylist: onAddToPlaylist,
                onRequestDelete: { item in Task { await library.delete(item) } },
            )
        }
    }

    /// Log `select_content` attributed to the originating section, then open. A non-empty search query overrides the
    /// section so opens from search results are attributed to `.searchResult`.
    private func openScore(_ item: ScoreItem) {
        library.analytics.log(.scoreOpened(from: openSource))
        onOpen(item)
    }

    private var openSource: AnalyticsSource {
        if !viewModel.searchQuery.isEmpty {
            return .searchResult
        }
        switch viewModel.source {
        case .all: return .libraryAll
        case .favorites: return .favorites
        case .taggedWith: return .tag
        case .playlist: return .playlist
        }
    }

    private var isPlaylistSource: Bool {
        if case .playlist = viewModel.source {
            return true
        }
        return false
    }

    private var bulkContext: BulkContext {
        .scores
    }

    private var orderedSelectedIDs: [ScoreItemID] {
        viewModel.displayedItems
            .map(\.id)
            .filter { selectedIDs.contains($0) }
    }

    private var selectedItems: [ScoreItem] {
        viewModel.displayedItems.filter { selectedIDs.contains($0.id) }
    }

    private var allSelectedFavorited: Bool {
        let items = selectedItems
        return !items.isEmpty && items.allSatisfy(\.isFavorite)
    }

    private var bulkAvailableShareFormats: [ScoreShareFormat] {
        // Every item now reports the same four formats; the per-item `isOriginal` flag is meaningful only for the row
        // menu, not for the bulk one. `prepareShare` returns original bytes per-item where the source matches the
        // picked format.
        selectedItems.isEmpty ? [] : [.museScoreV4, .museScoreV3, .pdf, .midi]
    }

    private func performBulkShare(_ format: ScoreShareFormat) {
        let items = selectedItems
        Task { await library.requestBulkShare(items, format: format) }
    }

    private func exitSelectionMode() {
        selectedIDs = []
        isSelecting = false
    }
}
