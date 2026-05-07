import Domain
import SwiftUI

struct ScoreListView: View {
    @Bindable var viewModel: ScoreListViewModel
    let library: LibraryViewModel
    let onOpen: (ScoreItem) -> Void
    let onEditTags: (ScoreItem) -> Void
    let onAddToPlaylist: (ScoreItem) -> Void

    @State private var pendingDelete: ScoreItem?

    var body: some View {
        List {
            ForEach(viewModel.displayedItems) { item in
                row(for: item)
            }
        }
        .searchable(text: $viewModel.searchQuery)
        .toolbar { sortToolbarItem }
        .alert(
            Text("Delete \"\(pendingDelete?.title ?? "")\"?", bundle: .module),
            isPresented: deleteAlertBinding,
            presenting: pendingDelete
        ) { item in
            Button(role: .destructive) {
                Task { await library.delete(item) }
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
                .onTapGesture { onOpen(item) }
            Menu {
                scoreRowMenu(
                    item: item,
                    library: library,
                    onOpen: onOpen,
                    onEditTags: onEditTags,
                    onAddToPlaylist: onAddToPlaylist,
                    onRequestDelete: { pendingDelete = $0 }
                )
            } label: {
                Image(systemName: "ellipsis.circle")
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
                Task { await library.toggleFavorite(item) }
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
            if case .playlist = viewModel.source {
                Button {
                    viewModel.selectManualOrder()
                } label: {
                    Label {
                        Text("Manual Order", bundle: .module)
                    } icon: {
                        Image(systemName: viewModel.isManualOrderActive ? "checkmark" : "")
                    }
                }
                Divider()
            }
            ForEach(ScoreItemSort.allCases) { option in
                Button {
                    viewModel.selectSort(option)
                } label: {
                    let isSelected = !viewModel.isManualOrderActive && viewModel.sort == option
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
