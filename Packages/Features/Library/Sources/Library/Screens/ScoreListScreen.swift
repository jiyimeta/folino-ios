import Domain
import SwiftUI

struct ScoreListScreen: View {
    @Bindable var viewModel: ScoreListViewModel
    let library: LibraryViewModel
    let onOpen: (ScoreItem) -> Void
    let onEditTags: (ScoreItem) -> Void
    let onAddToPlaylist: (ScoreItem) -> Void

    @State private var pendingDelete: ScoreItem?

    var body: some View {
        ScoreListView(
            items: viewModel.displayedItems,
            searchText: $viewModel.searchQuery,
            sort: viewModel.sort,
            isManualOrderActive: viewModel.isManualOrderActive,
            showsManualOrderOption: isPlaylistSource,
            pendingDelete: $pendingDelete,
            onTap: onOpen,
            onToggleFavorite: { item in Task { await library.toggleFavorite(item) } },
            onConfirmDelete: { item in Task { await library.delete(item) } },
            onSelectSort: { viewModel.selectSort($0) },
            onSelectManualOrder: { viewModel.selectManualOrder() }
        ) { item in
            scoreRowMenu(
                item: item,
                library: library,
                onOpen: onOpen,
                onEditTags: onEditTags,
                onAddToPlaylist: onAddToPlaylist,
                onRequestDelete: { pendingDelete = $0 }
            )
        }
    }

    private var isPlaylistSource: Bool {
        if case .playlist = viewModel.source { return true }
        return false
    }
}
