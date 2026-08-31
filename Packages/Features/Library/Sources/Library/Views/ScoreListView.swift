import Domain
import SwiftUI
import UtilityUI

enum BulkContext {
    case scores
    case playlist
}

private struct SelectionTitleModifier: ViewModifier {
    let isShowingSelectionCount: Bool
    let selectionCount: Int

    func body(content: Content) -> some View {
        if isShowingSelectionCount {
            let title = String(
                localized: "library.selection.count",
                defaultValue: "\(selectionCount) selected",
                bundle: .module,
            )
            content.navigationTitle(Text(title))
        } else {
            content
        }
    }
}

struct ScoreListView<RowMenu: View>: View {
    let items: [ScoreItem]
    @Binding var searchText: String
    let sort: ScoreItemSort
    let isManualOrderActive: Bool
    let showsManualOrderOption: Bool
    let onTap: (ScoreItem) -> Void
    let onToggleFavorite: (ScoreItem) -> Void
    /// Invoked when the user picks Delete in the row context menu or the trailing swipe. Soft-delete, so no
    /// confirmation alert.
    let onConfirmDelete: (ScoreItem) -> Void
    let onSelectSort: (ScoreItemSort) -> Void
    let onSelectManualOrder: () -> Void
    @Binding var isSelecting: Bool
    @Binding var selectedIDs: Set<ScoreItemID>
    let bulkContext: BulkContext
    let availableShareFormats: [ScoreShareFormat]
    let onBulkShare: (ScoreShareFormat) -> Void
    let onBulkAddToPlaylist: () -> Void
    let onBulkEditTags: () -> Void
    let onBulkFavorite: () -> Void
    let allSelectedFavorited: Bool
    let onBulkDelete: () -> Void
    @ViewBuilder let rowMenu: (ScoreItem) -> RowMenu

    var body: some View {
        listWithChrome
            .modifier(SelectionTitleModifier(
                isShowingSelectionCount: isShowingSelectionCount,
                selectionCount: selectedIDs.count,
            ))
    }

    // PARITY(macos): bulk-selection chrome — iOS needs an explicit Select mode because a touch list cannot distinguish
    //   a tap-to-open from a tap-to-select. AppKit's List multi-selects natively with ⌘/⇧-click, so the Mac has no mode
    //   and reaches the same bulk actions from the selection's context menu (and, in sub-project Ⅳ, the menu bar).
    private var listWithChrome: some View {
        list
            .searchable(text: $searchText)
            .toolbar { trailingToolbarItems }
            .bulkSelectionEditModeCompat(isSelecting: isSelecting)
            .safeAreaInset(edge: .bottom) {
                #if os(iOS)
                if isSelecting {
                    BulkActionBar(
                        selectionCount: selectedIDs.count,
                        availableShareFormats: availableShareFormats,
                        onShare: onBulkShare,
                        onAddToPlaylist: onBulkAddToPlaylist,
                        onEditTags: onBulkEditTags,
                        allFavorited: allSelectedFavorited,
                        onFavorite: onBulkFavorite,
                        onDelete: onBulkDelete,
                    )
                }
                #endif
            }
    }

    private var list: some View {
        List(selection: $selectedIDs) {
            ForEach(items) { item in
                ScoreListRow(
                    item: item,
                    isSelecting: isSelecting,
                    onTap: onTap,
                    onToggleSelection: { toggleSelection(item.id) },
                    onToggleFavorite: onToggleFavorite,
                    onConfirmDelete: onConfirmDelete,
                    rowMenu: rowMenu,
                )
                .tag(item.id)
            }
        }
    }

    private var isShowingSelectionCount: Bool {
        isSelecting && !selectedIDs.isEmpty
    }

    @ToolbarContentBuilder
    private var trailingToolbarItems: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailingCompat) {
            ScoreSortMenu(
                isManualOrderActive: isManualOrderActive,
                sort: sort,
                showsManualOrderOption: showsManualOrderOption,
                onSelectSort: onSelectSort,
                onSelectManualOrder: onSelectManualOrder,
            )
        }
        if #available(iOS 26, macOS 26, *) {
            ToolbarSpacer(.fixed, placement: .topBarTrailingCompat)
        }
        #if os(iOS)
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                withAnimation {
                    if isSelecting {
                        isSelecting = false
                        selectedIDs = []
                    } else {
                        isSelecting = true
                    }
                }
            } label: {
                (isSelecting ? L10n.Common.cancel : L10n.Common.select)
                    .contentTransition(.identity)
            }
        }
        #endif
    }

    private func toggleSelection(_ id: ScoreItemID) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }
}

#if DEBUG
private enum ScoreListViewPreview {
    static func item(
        title: String,
        composer: String?,
        isFavorite: Bool = false,
        addedDaysAgo: Int = 0,
    ) -> ScoreItem {
        ScoreItem(
            title: title,
            composer: composer,
            instrumentationSummary: "Piano",
            localFileName: "\(UUID().uuidString).musicxml",
            contentHash: String(repeating: "0", count: 64),
            sizeBytes: 1024,
            lengthBeats: 256,
            defaultTempoBpm: 120,
            primaryKey: nil,
            addedAt: Date().addingTimeInterval(TimeInterval(-addedDaysAgo * 86400)),
            lastOpenedAt: nil,
            tagIDs: [],
            isFavorite: isFavorite,
        )
    }

    static let sample: [ScoreItem] = [
        item(title: "Clair de Lune", composer: "Debussy", isFavorite: true, addedDaysAgo: 1),
        item(title: "Gymnopédie No. 1", composer: "Satie", addedDaysAgo: 3),
        item(title: "Prelude in C Major", composer: "Bach", addedDaysAgo: 7),
        item(title: "Untitled Sketch", composer: nil, addedDaysAgo: 12),
    ]
}

private struct ScoreListViewPreviewHost: View {
    @State private var searchText = ""
    @State private var sort: ScoreItemSort = .dateAddedDesc
    @State private var isManualOrderActive = false
    @State private var isSelecting = false
    @State private var selectedIDs: Set<ScoreItemID> = []

    let items: [ScoreItem]
    let showsManualOrderOption: Bool

    var body: some View {
        NavigationStack {
            ScoreListView(
                items: items,
                searchText: $searchText,
                sort: sort,
                isManualOrderActive: isManualOrderActive,
                showsManualOrderOption: showsManualOrderOption,
                onTap: { _ in },
                onToggleFavorite: { _ in },
                onConfirmDelete: { _ in },
                onSelectSort: { sort = $0; isManualOrderActive = false },
                onSelectManualOrder: { isManualOrderActive = true },
                isSelecting: $isSelecting,
                selectedIDs: $selectedIDs,
                bulkContext: .scores,
                availableShareFormats: [],
                onBulkShare: { _ in },
                onBulkAddToPlaylist: {},
                onBulkEditTags: {},
                onBulkFavorite: {},
                allSelectedFavorited: false,
                onBulkDelete: {},
            ) { _ in
                Button {} label: { L10n.Common.open }
                Button(role: .destructive) {} label: { L10n.Common.delete }
            }
            .navigationTitle(Text("library.allScores", bundle: .module))
        }
    }
}

#Preview("Filled") {
    ScoreListViewPreviewHost(items: ScoreListViewPreview.sample, showsManualOrderOption: false)
}

#Preview("Empty") {
    ScoreListViewPreviewHost(items: [], showsManualOrderOption: false)
}

#Preview("Playlist") {
    ScoreListViewPreviewHost(items: ScoreListViewPreview.sample, showsManualOrderOption: true)
}

// Proves the iOS bulk-selection chrome (Select/Cancel button, row checkmarks, `BulkActionBar`) is unaffected by the
// `EditMode` → `isSelecting` rename — two rows pre-selected, `isSelecting` pinned on.
#Preview("Selecting") {
    NavigationStack {
        ScoreListView(
            items: ScoreListViewPreview.sample,
            searchText: .constant(""),
            sort: .dateAddedDesc,
            isManualOrderActive: false,
            showsManualOrderOption: false,
            onTap: { _ in },
            onToggleFavorite: { _ in },
            onConfirmDelete: { _ in },
            onSelectSort: { _ in },
            onSelectManualOrder: {},
            isSelecting: .constant(true),
            selectedIDs: .constant(Set(ScoreListViewPreview.sample.prefix(2).map(\.id))),
            bulkContext: .scores,
            availableShareFormats: [.museScoreV4, .museScoreV3, .pdf, .midi],
            onBulkShare: { _ in },
            onBulkAddToPlaylist: {},
            onBulkEditTags: {},
            onBulkFavorite: {},
            allSelectedFavorited: false,
            onBulkDelete: {},
        ) { _ in
            Button {} label: { L10n.Common.open }
            Button(role: .destructive) {} label: { L10n.Common.delete }
        }
        .navigationTitle(Text("library.allScores", bundle: .module))
    }
}
#endif
