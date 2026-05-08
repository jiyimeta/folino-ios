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
                bundle: .module
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
    @Binding var pendingDelete: ScoreItem?
    let onTap: (ScoreItem) -> Void
    let onToggleFavorite: (ScoreItem) -> Void
    let onConfirmDelete: (ScoreItem) -> Void
    let onSelectSort: (ScoreItemSort) -> Void
    let onSelectManualOrder: () -> Void
    @Binding var editMode: EditMode
    @Binding var selectedIDs: Set<ScoreItemID>
    let bulkContext: BulkContext
    let availableShareFormats: [ScoreShareFormat]
    let onBulkShare: (ScoreShareFormat) -> Void
    let onBulkAddToPlaylist: () -> Void
    let onBulkEditTags: () -> Void
    let onBulkDelete: () -> Void
    @ViewBuilder let rowMenu: (ScoreItem) -> RowMenu

    var body: some View {
        listWithChrome
            .modifier(SelectionTitleModifier(
                isShowingSelectionCount: isShowingSelectionCount,
                selectionCount: selectedIDs.count
            ))
    }

    @ViewBuilder
    private var listWithChrome: some View {
        list
            .searchable(text: $searchText)
            .toolbar { trailingToolbarItems }
            .environment(\.editMode, $editMode)
            .safeAreaInset(edge: .bottom) {
                if isEditing {
                    BulkActionBar(
                        selectionCount: selectedIDs.count,
                        availableShareFormats: availableShareFormats,
                        onShare: onBulkShare,
                        onAddToPlaylist: onBulkAddToPlaylist,
                        onEditTags: onBulkEditTags,
                        onDelete: onBulkDelete
                    )
                }
            }
            .alert(
                Text(String(
                    localized: "library.score.delete.title",
                    defaultValue: "Delete \"\(pendingDelete?.title ?? "")\"?",
                    bundle: .module
                )),
                isPresented: deleteAlertBinding,
                presenting: pendingDelete
            ) { item in
                Button(role: .destructive) {
                    onConfirmDelete(item)
                } label: {
                    L10n.Common.delete
                }
                Button(role: .cancel) {} label: {
                    L10n.Common.cancel
                }
            } message: { _ in
                Text("library.score.delete.message", bundle: .module)
            }
    }

    @ViewBuilder
    private var list: some View {
        List(selection: $selectedIDs) {
            ForEach(items) { item in
                row(for: item)
                    .tag(item.id)
            }
        }
    }

    private var isEditing: Bool {
        editMode.isEditing
    }

    private var isShowingSelectionCount: Bool {
        isEditing && !selectedIDs.isEmpty
    }

    @ToolbarContentBuilder
    private var trailingToolbarItems: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) { sortMenu }
        ToolbarSpacer(.fixed, placement: .topBarTrailing)
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                withAnimation {
                    if editMode.isEditing {
                        editMode = .inactive
                        selectedIDs = []
                    } else {
                        editMode = .active
                    }
                }
            } label: {
                (editMode.isEditing ? L10n.Common.cancel : L10n.Common.select)
                    .contentTransition(.identity)
            }
        }
    }

    @ViewBuilder
    private func row(for item: ScoreItem) -> some View {
        HStack(spacing: 0) {
            ScoreRow(scoreItem: item)
                .contentShape(Rectangle())
                .onTapGesture {
                    if isEditing {
                        toggleSelection(item.id)
                    } else {
                        onTap(item)
                    }
                }
            if !isEditing {
                Menu {
                    rowMenu(item)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 34)
                        .frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.Common.more)
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                onToggleFavorite(item)
            } label: {
                Label {
                    let key: LocalizedStringKey = item.isFavorite
                        ? "library.score.unfavorite.action"
                        : "library.score.favorite.action"
                    Text(key, bundle: .module)
                } icon: {
                    Image(systemName: item.isFavorite ? "star.slash.fill" : "star.fill")
                }
            }
            .tint(.yellow)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                pendingDelete = item
            } label: {
                Label {
                    L10n.Common.delete
                } icon: {
                    Image(systemName: "trash")
                }
            }
        }
        .contextMenu {
            rowMenu(item)
        }
    }

    private func toggleSelection(_ id: ScoreItemID) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    private var deleteAlertBinding: Binding<Bool> {
        Binding(
            get: { pendingDelete != nil },
            set: { isPresented in if !isPresented { pendingDelete = nil } }
        )
    }

    private var sortMenu: some View {
        Menu {
            if showsManualOrderOption {
                Button {
                    onSelectManualOrder()
                } label: {
                    Label {
                        Text("library.sort.manualOrder", bundle: .module)
                    } icon: {
                        Image(systemName: isManualOrderActive ? "checkmark" : "")
                    }
                }
                Divider()
            }
            ForEach(ScoreItemSort.allCases) { option in
                Button {
                    onSelectSort(option)
                } label: {
                    let isSelected = !isManualOrderActive && sort == option
                    Label {
                        Text(option.labelKey)
                    } icon: {
                        Image(systemName: isSelected ? "checkmark" : "")
                    }
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .accessibilityLabel(Text("library.sort.menu", bundle: .module))
        }
    }
}

#if DEBUG
    private enum ScoreListViewPreview {
        static func item(
            title: String,
            composer: String?,
            isFavorite: Bool = false,
            addedDaysAgo: Int = 0
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
                isFavorite: isFavorite
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
        @State private var searchText: String = ""
        @State private var pendingDelete: ScoreItem?
        @State private var sort: ScoreItemSort = .dateAddedDesc
        @State private var isManualOrderActive: Bool = false
        @State private var editMode: EditMode = .inactive
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
                    pendingDelete: $pendingDelete,
                    onTap: { _ in },
                    onToggleFavorite: { _ in },
                    onConfirmDelete: { _ in },
                    onSelectSort: { sort = $0; isManualOrderActive = false },
                    onSelectManualOrder: { isManualOrderActive = true },
                    editMode: $editMode,
                    selectedIDs: $selectedIDs,
                    bulkContext: .scores,
                    availableShareFormats: [],
                    onBulkShare: { _ in },
                    onBulkAddToPlaylist: {},
                    onBulkEditTags: {},
                    onBulkDelete: {}
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
#endif
