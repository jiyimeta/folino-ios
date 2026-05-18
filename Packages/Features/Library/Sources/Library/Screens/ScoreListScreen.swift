import Domain
import SwiftUI
import UtilityUI

struct ScoreListScreen: View {
    @Bindable var viewModel: ScoreListViewModel
    let library: LibraryViewModel
    let onOpen: (ScoreItem) -> Void
    let onEditTags: (ScoreItem) -> Void
    let onAddToPlaylist: (ScoreItem) -> Void

    @State private var pendingRename: ScoreItem?
    @State private var renameText = ""
    @State private var editMode: EditMode = .inactive
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
            .alert(
                Text("library.score.rename.title", bundle: .module),
                isPresented: renameAlertBinding,
                presenting: pendingRename,
            ) { item in
                TextField(text: $renameText) {
                    Text("library.score.rename.placeholder", bundle: .module)
                }
                Button {
                    let newTitle = renameText
                    Task { await library.rename(item, to: newTitle) }
                } label: { L10n.Common.save }
                Button(role: .cancel) {} label: { L10n.Common.cancel }
            }
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
            onTap: onOpen,
            onToggleFavorite: { item in Task { await library.toggleFavorite(item) } },
            onConfirmDelete: { item in Task { await library.delete(item) } },
            onSelectSort: { viewModel.selectSort($0) },
            onSelectManualOrder: { viewModel.selectManualOrder() },
            editMode: $editMode,
            selectedIDs: $selectedIDs,
            bulkContext: bulkContext,
            availableShareFormats: bulkAvailableShareFormats,
            onBulkShare: { format in performBulkShare(format) },
            onBulkAddToPlaylist: { bulkSheet = .addToPlaylist },
            onBulkEditTags: { bulkSheet = .editTags },
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
                onOpen: onOpen,
                onRename: { item in
                    renameText = item.title
                    pendingRename = item
                },
                onEditTags: onEditTags,
                onAddToPlaylist: onAddToPlaylist,
                onRequestDelete: { item in Task { await library.delete(item) } },
            )
        }
    }

    private var renameAlertBinding: Binding<Bool> {
        Binding(
            get: { pendingRename != nil },
            set: { isPresented in if !isPresented { pendingRename = nil } },
        )
    }

    private var isPlaylistSource: Bool {
        if case .playlist = viewModel.source { return true }
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

    private var bulkAvailableShareFormats: [ScoreShareFormat] {
        // Every item now reports the same four formats; the per-item
        // `isOriginal` flag is meaningful only for the row menu, not
        // for the bulk one. `prepareShare` returns original bytes
        // per-item where the source matches the picked format.
        selectedItems.isEmpty ? [] : [.museScoreV4, .museScoreV3, .pdf, .midi]
    }

    private func performBulkShare(_ format: ScoreShareFormat) {
        let items = selectedItems
        Task { await library.requestBulkShare(items, format: format) }
    }

    private func exitSelectionMode() {
        selectedIDs = []
        editMode = .inactive
    }
}
