import Domain
import SwiftUI

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
    @ViewBuilder let rowMenu: (ScoreItem) -> RowMenu

    var body: some View {
        List {
            ForEach(items) { item in
                row(for: item)
            }
        }
        .searchable(text: $searchText)
        .toolbar { sortToolbarItem }
        .alert(
            Text("Delete \"\(pendingDelete?.title ?? "")\"?", bundle: .module),
            isPresented: deleteAlertBinding,
            presenting: pendingDelete
        ) { item in
            Button(role: .destructive) {
                onConfirmDelete(item)
            } label: {
                Text("Delete", bundle: .module)
            }
            Button(role: .cancel) {} label: {
                Text("Cancel", bundle: .module)
            }
        } message: { _ in
            Text("This will remove the score and its file from this device.", bundle: .module)
        }
    }

    @ViewBuilder
    private func row(for item: ScoreItem) -> some View {
        HStack(spacing: 0) {
            ScoreRow(scoreItem: item)
                .contentShape(Rectangle())
                .onTapGesture { onTap(item) }
            Menu {
                rowMenu(item)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("More", bundle: .module))
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                onToggleFavorite(item)
            } label: {
                Label {
                    Text(item.isFavorite ? "Unfavorite" : "Favorite", bundle: .module)
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
                    Text("Delete", bundle: .module)
                } icon: {
                    Image(systemName: "trash")
                }
            }
        }
        .contextMenu {
            rowMenu(item)
        }
    }

    private var deleteAlertBinding: Binding<Bool> {
        Binding(
            get: { pendingDelete != nil },
            set: { isPresented in if !isPresented { pendingDelete = nil } }
        )
    }

    @ToolbarContentBuilder
    private var sortToolbarItem: some ToolbarContent {
        #if os(iOS)
            ToolbarItem(placement: .topBarTrailing) { sortMenu }
        #else
            ToolbarItem(placement: .automatic) { sortMenu }
        #endif
    }

    private var sortMenu: some View {
        Menu {
            if showsManualOrderOption {
                Button {
                    onSelectManualOrder()
                } label: {
                    Label {
                        Text("Manual Order", bundle: .module)
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
                .accessibilityLabel(Text("Sort", bundle: .module))
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
                    onSelectManualOrder: { isManualOrderActive = true }
                ) { _ in
                    Button("Open") {}
                    Button("Delete", role: .destructive) {}
                }
                .navigationTitle("All Scores")
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
