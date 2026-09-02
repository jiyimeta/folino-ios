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
    /// **macOS only**, in effect: iOS passes the same closure as `onTap` (no window concept there), so this call
    /// site never changes iOS's meaning. See `RowOpenAffordance.macScoreOpenAffordance`.
    let onOpenInNewWindow: (ScoreItem) -> Void
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

    // PARITY(macos): bulk-selection chrome — iOS needs an explicit Select mode because a touch list cannot
    //   distinguish a tap-to-open from a tap-to-select. macOS needs no mode: `List(selection:)` multi-selects
    //   with ⌘/⇧-click, the same bulk actions come from a context menu on the selection, and ⌫ deletes it.
    //   That works ONLY because the row carries no tap gesture there — any SwiftUI tap gesture leaves the
    //   selection permanently EMPTY, which silently made the context menu and ⌫ unreachable for two tasks
    //   before it was measured. Opening is its own action now, never a side effect of selecting a row — see
    //   `RowOpenAffordance` for the measurement and for both halves of the per-platform decision. Still open: the
    //   menu bar (Ⅳ).
    private var listWithChrome: some View {
        list
            .macScoreOpenAffordance(selectedIDs, in: items, onOpen: onTap, onOpenInNewWindow: onOpenInNewWindow)
            .searchable(text: $searchText)
            .toolbar { trailingToolbarItems }
            .bulkSelectionEditModeCompat(isSelecting: isSelecting)
            .deleteCommandCompat {
                guard !selectedIDs.isEmpty else { return }
                onBulkDelete()
            }
            .bulkActionBarInsetCompat {
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
                    rowMenu: { rowItem in effectiveRowMenu(for: rowItem) },
                )
                .tag(item.id)
            }
        }
    }

    /// The row's own menu, unless this row is part of a multi-item selection — right-clicking anywhere inside a
    /// ⌘/⇧-click selection then offers the bulk actions instead, mirroring how AppKit list views resolve a
    /// selection-vs-single-item context menu. A single selected row keeps the row menu, which already offers
    /// everything the bulk menu does (plus Open / Edit Info), so nothing is lost there.
    ///
    /// On macOS, Open in New Window is appended here too — this is where `macScoreOpenAffordance` says Open items
    /// belong now that its own `menu:` closure is empty (see that helper's doc comment). `rowMenu(item)` already
    /// contains Open (`scoreRowMenu`'s first button), so only the new action is added.
    @ViewBuilder
    private func effectiveRowMenu(for item: ScoreItem) -> some View {
        #if os(macOS)
        if selectedIDs.contains(item.id), selectedIDs.count > 1 {
            bulkActionsMenuContent
        } else {
            rowMenu(item)
            Button { onOpenInNewWindow(item) } label: {
                Text("library.open.newWindow", bundle: .module)
            }
        }
        #else
        rowMenu(item)
        #endif
    }

    #if os(macOS)
    /// The same actions iOS's `BulkActionBar` offers. `bulkActionsContextMenuItems` is the single source of truth
    /// this shares with `PlaylistDetailView`'s identical menu, so a change to the action list reaches both.
    private var bulkActionsMenuContent: some View {
        bulkActionsContextMenuItems(
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
                onOpenInNewWindow: { _ in },
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
            onOpenInNewWindow: { _ in },
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
