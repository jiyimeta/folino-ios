import Domain
import SwiftUI

/// Reusable list of scores. Driven by `ScoreListViewModel`. Caller supplies
/// `onOpen` to handle the row tap (the App composition translates this into
/// either a NavigationStack push or a NavigationSplitView detail selection).
struct ScoreListView: View {
    @Bindable var viewModel: ScoreListViewModel
    let onOpen: (ScoreItem) -> Void

    var body: some View {
        List {
            ForEach(viewModel.displayedItems) { item in
                ScoreRow(scoreItem: item)
                    .onTapGesture { onOpen(item) }
            }
        }
        .searchable(text: $viewModel.searchQuery)
        .toolbar { sortToolbarItem }
    }

    @ToolbarContentBuilder
    private var sortToolbarItem: some ToolbarContent {
        ToolbarItem(placement: {
            #if os(iOS)
                ToolbarItemPlacement.topBarTrailing
            #else
                ToolbarItemPlacement.automatic
            #endif
        }()) {
            Menu {
                if case .playlist = viewModel.source {
                    Button {
                        viewModel.selectManualOrder()
                    } label: {
                        Label("Manual Order", systemImage: viewModel.isManualOrderActive ? "checkmark" : "")
                    }
                    Divider()
                }
                ForEach(ScoreItemSort.allCases) { option in
                    Button {
                        viewModel.selectSort(option)
                    } label: {
                        let isSelected = !viewModel.isManualOrderActive && viewModel.sort == option
                        Label(option.labelKey, systemImage: isSelected ? "checkmark" : "")
                    }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .accessibilityLabel("Sort")
            }
        }
    }
}
