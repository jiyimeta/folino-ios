import Domain
import SwiftUI
import UtilityUI

/// Recently Deleted (trash) screen. Items are sorted most-recently-deleted first. Soft-delete is silent; this screen is
/// where permanent removal and restoration happen, plus the 30-day retention window.
struct RecentlyDeletedScreen: View {
    let library: LibraryViewModel
    let onOpen: (ScoreItem) -> Void

    @State private var viewModel: RecentlyDeletedViewModel
    @State private var isSelecting = false
    @State private var selectedIDs: Set<ScoreItemID> = []
    @State private var pendingPermanentDelete: ScoreItem?
    @State private var isShowingBulkPermanentDeletePopover = false

    init(
        library: LibraryViewModel,
        onOpen: @escaping (ScoreItem) -> Void,
    ) {
        self.library = library
        self.onOpen = onOpen
        _viewModel = State(wrappedValue: RecentlyDeletedViewModel(repository: library.repository))
    }

    var body: some View {
        Group {
            let items = viewModel.displayedItems
            if items.isEmpty {
                ContentUnavailableView {
                    Label {
                        Text("library.recentlyDeleted.empty.title", bundle: .module)
                    } icon: {
                        Image(systemName: "trash")
                    }
                } description: {
                    Text("library.recentlyDeleted.empty.message", bundle: .module)
                }
            } else {
                recentlyDeletedList(items: items)
            }
        }
        .navigationTitle(Text("library.recentlyDeleted.title", bundle: .module))
        .modifier(SelectionTitleModifierForTrash(
            isShowingSelectionCount: isSelecting && !selectedIDs.isEmpty,
            selectionCount: selectedIDs.count,
        ))
        // PARITY(macos): bulk-selection chrome — iOS needs an explicit Select mode because a touch list cannot
        //   distinguish a tap-to-open from a tap-to-select. macOS needs no mode: `List(selection:)` multi-selects
        //   with ⌘/⇧-click, the same bulk actions come from a context menu on the selection, and ⌫ deletes it.
        //   That works ONLY because the row carries no tap gesture there — any SwiftUI tap gesture leaves the
        //   selection permanently EMPTY, which silently made the context menu and ⌫ unreachable for two tasks
        //   before it was measured. Opening is its own action now, never a side effect of selecting a row — see
        //   `RowOpenAffordance` for the measurement and for both halves of the per-platform decision. Still open:
        //   the menu bar (Ⅳ).
        .toolbar {
            #if os(iOS)
            ToolbarItem(placement: .topBarTrailing) {
                if !viewModel.displayedItems.isEmpty {
                    Button {
                        withAnimation {
                            if isSelecting {
                                exitSelectionMode()
                            } else {
                                isSelecting = true
                            }
                        }
                    } label: {
                        (isSelecting ? L10n.Common.cancel : L10n.Common.select)
                            .contentTransition(.identity)
                    }
                }
            }
            #endif
        }
        .onAppear { library.analytics.logScreen(.recentlyDeleted) }
    }

    /// Split out of `body` to keep the `Group` closure under SwiftLint's `closure_body_length` budget.
    private func recentlyDeletedList(items: [ScoreItem]) -> some View {
        RecentlyDeletedView(
            items: items,
            onTap: onOpen,
            onRestore: { item in Task { await library.restore(item) } },
            onRequestPermanentDelete: { pendingPermanentDelete = $0 },
            pendingPermanentDelete: $pendingPermanentDelete,
            onConfirmPermanentDelete: { item in
                Task { await library.permanentlyDelete(item) }
            },
            isSelecting: $isSelecting,
            selectedIDs: $selectedIDs,
            onBulkRestore: {
                let ids = selectedIDs
                Task {
                    await library.bulkRestore(ids)
                    exitSelectionMode()
                }
            },
            onBulkPermanentDelete: {
                let ids = selectedIDs
                Task {
                    await library.bulkPermanentlyDelete(ids)
                    exitSelectionMode()
                }
            },
            isShowingBulkPermanentDeletePopover: $isShowingBulkPermanentDeletePopover,
        )
    }

    private func exitSelectionMode() {
        selectedIDs = []
        isSelecting = false
        isShowingBulkPermanentDeletePopover = false
    }
}

private struct SelectionTitleModifierForTrash: ViewModifier {
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

#if DEBUG
private enum RecentlyDeletedPreview {
    static func item(title: String, deletedDaysAgo: Int) -> ScoreItem {
        ScoreItem(
            title: title,
            composer: "Sample Composer",
            instrumentationSummary: "Piano",
            localFileName: "\(UUID().uuidString).musicxml",
            contentHash: String(repeating: "0", count: 64),
            sizeBytes: 1024,
            lengthBeats: 256,
            defaultTempoBpm: 120,
            primaryKey: nil,
            addedAt: Date().addingTimeInterval(TimeInterval(-(deletedDaysAgo + 5) * 86400)),
            lastOpenedAt: nil,
            tagIDs: [],
            isFavorite: false,
            deletedAt: Date().addingTimeInterval(TimeInterval(-deletedDaysAgo * 86400)),
        )
    }
}
#endif
