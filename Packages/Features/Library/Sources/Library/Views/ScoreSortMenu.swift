import Domain
import SwiftUI

/// The sort menu in `ScoreListView`'s trailing toolbar. Takes only the narrow inputs it reads — the active sort,
/// whether manual order is in effect, and whether the manual-order option should appear — so it invalidates
/// independently of the rest of the list chrome.
struct ScoreSortMenu: View {
    let isManualOrderActive: Bool
    let sort: ScoreItemSort
    let showsManualOrderOption: Bool
    let onSelectSort: (ScoreItemSort) -> Void
    let onSelectManualOrder: () -> Void

    var body: some View {
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
