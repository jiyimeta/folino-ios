import Domain
import SwiftUI
import UtilityUI

/// One row in `ScoreListView`'s `List`. Takes only the narrow inputs a row reads so it invalidates independently of
/// its siblings — the tap/swipe/menu wiring is passed in as closures and `rowMenu` builder, mirroring the
/// section/row factoring in `LibraryRootBrowseSection` and friends.
struct ScoreListRow<RowMenu: View>: View {
    let item: ScoreItem
    let isSelecting: Bool
    let onTap: (ScoreItem) -> Void
    let onToggleSelection: () -> Void
    let onToggleFavorite: (ScoreItem) -> Void
    /// Invoked when the user picks Delete in the row context menu or the trailing swipe. Soft-delete, so no
    /// confirmation alert.
    let onConfirmDelete: (ScoreItem) -> Void
    @ViewBuilder let rowMenu: (ScoreItem) -> RowMenu

    var body: some View {
        HStack(spacing: 0) {
            ScoreRow(scoreItem: item)
                .contentShape(Rectangle())
                .onTapGesture {
                    if isSelecting {
                        onToggleSelection()
                    } else {
                        onTap(item)
                    }
                }
            if !isSelecting {
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
        // No `role: .destructive` — see `LibraryRootScreen.sectionRow`. Soft-delete: no confirmation, just stamp
        // `deletedAt`. The item moves into Recently Deleted where the user can restore within 30 days.
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                onConfirmDelete(item)
            } label: {
                Label {
                    L10n.Common.delete
                } icon: {
                    Image(systemName: "trash")
                }
            }
            .tint(.red)
        }
        .contextMenu {
            rowMenu(item)
        }
    }
}
