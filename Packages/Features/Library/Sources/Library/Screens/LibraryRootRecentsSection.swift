import Domain
import SwiftUI
import UtilityCore
import UtilityUI

/// The Library root's "Recently Opened" section. Extracted into its own `View` so the per-row machinery (tap-to-open,
/// overflow menu, swipe actions, context menu) forms its own invalidation boundary instead of inflating
/// `LibraryRootScreen.body`. The sheet-presentation targets are passed in as bindings so the rows can drive the
/// screen's sheets without reaching back into it.
@MainActor
struct LibraryRootRecentsSection: View {
    let recents: [ScoreItem]
    let viewModel: LibraryViewModel
    let onOpenScore: (ScoreItem) -> Void
    @Binding var editInfoTarget: ScoreItem?
    @Binding var editTagsTarget: ScoreItem?
    @Binding var addToPlaylistTarget: ScoreItem?

    var body: some View {
        if !recents.isEmpty {
            Section {
                ForEach(recents) { item in
                    sectionRow(for: item)
                }
            } header: {
                Text("library.recentlyOpened", bundle: .module)
            }
        }
    }

    /// Log `select_content` from the recently-opened section, then open.
    private func openScore(_ item: ScoreItem) {
        viewModel.analytics.log(.scoreOpened(from: .recentlyOpened))
        onOpenScore(item)
    }

    private func sectionRowMenu(for item: ScoreItem) -> some View {
        scoreRowMenu(
            item: item,
            library: viewModel,
            onOpen: openScore,
            onEditInfo: { item in editInfoTarget = item },
            onEditTags: { editTagsTarget = $0 },
            onAddToPlaylist: { addToPlaylistTarget = $0 },
            onRequestDelete: { item in Task { await viewModel.delete(item) } },
        )
    }

    private func sectionRow(for item: ScoreItem) -> some View {
        HStack(spacing: 0) {
            ScoreRow(scoreItem: item)
                .contentShape(Rectangle())
                .onTapGesture { openScore(item) }
            Menu {
                sectionRowMenu(for: item)
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 34)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.Common.more)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                Task { await viewModel.toggleFavorite(item) }
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
        // No `role: .destructive`: it would make SwiftUI hide the row immediately on tap (same contract as
        // `.onDelete`), which can crash multi-section Lists. Soft-delete is silent (no confirm); the item moves into
        // Recently Deleted.
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                Task { await viewModel.delete(item) }
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
            sectionRowMenu(for: item)
        }
    }
}
