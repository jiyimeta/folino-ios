import Domain
import SwiftUI
import UtilityUI

struct ScoreListScreen: View {
    @Bindable var viewModel: ScoreListViewModel
    let library: LibraryViewModel
    let onOpen: (ScoreItem) -> Void
    let onEditTags: (ScoreItem) -> Void
    let onAddToPlaylist: (ScoreItem) -> Void

    @State private var pendingDelete: ScoreItem?
    #if os(iOS)
        @State private var editMode: EditMode = .inactive
    #endif
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
        listContent
            .sheet(item: $bulkSheet) { which in
                switch which {
                case .addToPlaylist:
                    BulkAddToPlaylistScreen(
                        selectedIDs: selectedIDs,
                        orderedSelectedIDs: orderedSelectedIDs,
                        library: library,
                        onCommit: { exitSelectionMode(); bulkSheet = nil }
                    )
                case .editTags:
                    BulkEditTagsScreen(
                        selectedIDs: selectedIDs,
                        library: library,
                        onCommit: { exitSelectionMode(); bulkSheet = nil }
                    )
                }
            }
            .alert(
                Text(String(
                    localized: "library.score.deleteBulk.title",
                    defaultValue: "Delete \(bulkDeletePrompt?.count ?? 0) scores?",
                    bundle: .module
                )),
                isPresented: bulkDeleteAlertBinding,
                presenting: bulkDeletePrompt
            ) { _ in
                Button(role: .destructive) {
                    let ids = selectedIDs
                    Task {
                        await library.bulkDelete(ids)
                        exitSelectionMode()
                    }
                } label: {
                    L10n.Common.delete
                }
                Button(role: .cancel) {} label: { L10n.Common.cancel }
            } message: { _ in
                Text("library.score.deleteBulk.message", bundle: .module)
            }
    }

    @ViewBuilder
    private var listContent: some View {
        #if os(iOS)
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
                onSelectManualOrder: { viewModel.selectManualOrder() },
                editMode: $editMode,
                selectedIDs: $selectedIDs,
                bulkContext: bulkContext,
                availableShareFormats: bulkAvailableShareFormats,
                onBulkShare: { format in performBulkShare(format) },
                onBulkAddToPlaylist: { bulkSheet = .addToPlaylist },
                onBulkEditTags: { bulkSheet = .editTags },
                onBulkDelete: { bulkDeletePrompt = BulkDeletePrompt(count: selectedIDs.count) }
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
        #else
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
                onSelectManualOrder: { viewModel.selectManualOrder() },
                selectedIDs: $selectedIDs,
                bulkContext: bulkContext,
                availableShareFormats: bulkAvailableShareFormats,
                onBulkShare: { format in performBulkShare(format) },
                onBulkAddToPlaylist: { bulkSheet = .addToPlaylist },
                onBulkEditTags: { bulkSheet = .editTags },
                onBulkDelete: { bulkDeletePrompt = BulkDeletePrompt(count: selectedIDs.count) }
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
        #endif
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
        let perItem = selectedItems.map { Set(library.shareService.availableFormats(for: $0)) }
        guard let first = perItem.first else { return [] }
        let intersection = perItem.dropFirst().reduce(first) { $0.intersection($1) }
        // Order: sourceFormat, pdf, midi (matches the row menu)
        return [.sourceFormat, .pdf, .midi].filter { intersection.contains($0) }
    }

    private func performBulkShare(_ format: ScoreShareFormat) {
        let items = selectedItems
        Task { await library.requestBulkShare(items, format: format) }
    }

    private var bulkDeleteAlertBinding: Binding<Bool> {
        Binding(
            get: { bulkDeletePrompt != nil },
            set: { isPresented in if !isPresented { bulkDeletePrompt = nil } }
        )
    }

    private func exitSelectionMode() {
        selectedIDs = []
        #if os(iOS)
            editMode = .inactive
        #endif
    }
}
