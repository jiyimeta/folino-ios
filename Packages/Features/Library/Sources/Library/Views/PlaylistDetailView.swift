import Domain
import SwiftUI
import UtilityUI

struct PlaylistDetailView: View {
    let playlistName: String
    let items: [ScoreItem]
    let onOpen: (ScoreItem) -> Void
    /// **macOS only**, in effect — see `ScoreListView.onOpenInNewWindow`.
    let onOpenInNewWindow: (ScoreItem) -> Void
    let onMove: (IndexSet, Int) -> Void
    let onRemoveFromPlaylist: (ScoreItem) -> Void
    let onRename: (String) -> Void
    let onDelete: () -> Void
    @Binding var selectedIDs: Set<ScoreItemID>
    let availableShareFormats: [ScoreShareFormat]
    let onBulkShare: (ScoreShareFormat) -> Void
    let onBulkAddToPlaylist: () -> Void
    let onBulkEditTags: () -> Void
    let onBulkFavorite: () -> Void
    let allBulkFavorited: Bool
    let onBulkDelete: () -> Void

    @State private var isSelecting = false

    var body: some View {
        Group {
            if items.isEmpty {
                ContentUnavailableView {
                    Label {
                        Text("library.playlist.empty.title", bundle: .module)
                    } icon: {
                        Image(systemName: "music.note.list")
                    }
                } description: {
                    Text("library.playlist.empty.hint", bundle: .module)
                }
            } else {
                List(selection: $selectedIDs) {
                    ForEach(items) { item in
                        ScoreRow(scoreItem: item)
                            .contentShape(Rectangle())
                            .rowTapToOpenCompat {
                                if isSelecting {
                                    toggleSelection(item.id)
                                } else {
                                    onOpen(item)
                                }
                            }
                            .tag(item.id)
                            // No `role: .destructive` — see `LibraryRootScreen.sectionRow`.
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                removeFromPlaylistButton(for: item)
                            }
                            .macContextMenuCompat { effectiveRowContextMenu(for: item) }
                    }
                    // Drag-reorder, and on macOS too: `.onMove` alone makes a row draggable there — no edit mode,
                    // no handle. Measured in Task 15 (a `List` row vends a `com.apple.SwiftUI.listReorder`
                    // pasteboard writer carrying `{"indexes":[…]}` only when the `ForEach` declares `.onMove`),
                    // which is why this screen ships no Mac-specific reorder affordance.
                    //
                    // The DRAG half is what was measured. SwiftUI gates the DROP on a live `NSDraggingSession`,
                    // which no in-process harness can construct, so the on-screen drop is still unverified by hand.
                    // If a Mac row picks up but will not drop, this is where the affordance goes.
                    .onMove(perform: onMove)
                }
                .deleteCommandCompat {
                    guard !selectedIDs.isEmpty else { return }
                    onBulkDelete()
                }
            }
        }
        // PARITY(macos): bulk-selection chrome — iOS needs an explicit Select mode because a touch list cannot
        //   distinguish a tap-to-open from a tap-to-select. macOS needs no mode: `List(selection:)` multi-selects
        //   with ⌘/⇧-click, the same bulk actions come from a context menu on the selection, and ⌫ deletes it.
        //   That works ONLY because the row carries no tap gesture there — any SwiftUI tap gesture leaves the
        //   selection permanently EMPTY, which silently made the context menu and ⌫ unreachable for two tasks
        //   before it was measured. Opening is its own action now, never a side effect of selecting a row — see
        //   `RowOpenAffordance` for the measurement and for both halves of the per-platform decision. Still open:
        //   the menu bar (Ⅳ).
        .macScoreOpenAffordance(selectedIDs, in: items, onOpen: onOpen, onOpenInNewWindow: onOpenInNewWindow)
        .safeAreaInset(edge: .bottom) {
            #if os(iOS)
            if isSelecting {
                BulkActionBar(
                    selectionCount: selectedIDs.count,
                    availableShareFormats: availableShareFormats,
                    onShare: onBulkShare,
                    onAddToPlaylist: onBulkAddToPlaylist,
                    onEditTags: onBulkEditTags,
                    allFavorited: allBulkFavorited,
                    onFavorite: onBulkFavorite,
                    onDelete: onBulkDelete,
                )
            }
            #endif
        }
        .navigationTitle(playlistName)
        .bulkSelectionEditModeCompat(isSelecting: isSelecting)
        .toolbar {
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
                    if isSelecting {
                        L10n.Common.cancel
                            .transition(.identity)
                    } else {
                        L10n.Common.select
                            .transition(.identity)
                    }
                }
            }
            #endif
        }
        .manageEntityToolbar(
            entityName: playlistName,
            copy: .playlist,
            onRename: onRename,
            onDelete: onDelete,
        )
    }

    /// The row's one action, in both the shapes this screen offers it: iOS's trailing swipe and (macOS) the row's
    /// context menu. One builder so the two cannot drift.
    private func removeFromPlaylistButton(for item: ScoreItem) -> some View {
        Button {
            onRemoveFromPlaylist(item)
        } label: {
            Label {
                Text("library.playlist.removeScore.action", bundle: .module)
            } icon: {
                Image(systemName: "minus.circle")
            }
        }
        .tint(.red)
    }

    /// The row's own Remove action, unless this row is part of a multi-item selection — right-clicking anywhere
    /// inside a ⌘/⇧-click selection then offers the bulk actions instead, exactly as `ScoreListView` does. Built on
    /// every platform because `macContextMenuCompat`'s builder is still type-checked on iOS; only macOS renders it.
    ///
    /// On macOS, Open / Open in New Window are prepended in the single-row branch too — this row has no tap gesture
    /// and no pre-existing "Open" menu item, so both live here; see `macScoreOpenAffordance`'s doc comment for why
    /// they belong in the row's own menu and not in a second one.
    @ViewBuilder
    private func effectiveRowContextMenu(for item: ScoreItem) -> some View {
        #if os(macOS)
        if selectedIDs.contains(item.id), selectedIDs.count > 1 {
            bulkActionsContextMenuItems(
                availableShareFormats: availableShareFormats,
                onShare: onBulkShare,
                onAddToPlaylist: onBulkAddToPlaylist,
                onEditTags: onBulkEditTags,
                allFavorited: allBulkFavorited,
                onFavorite: onBulkFavorite,
                onDelete: onBulkDelete,
            )
        } else {
            openRowContextMenuContent(for: item)
            Divider()
            removeFromPlaylistButton(for: item)
        }
        #else
        removeFromPlaylistButton(for: item)
        #endif
    }

    #if os(macOS)
    @ViewBuilder
    private func openRowContextMenuContent(for item: ScoreItem) -> some View {
        Button { onOpen(item) } label: {
            Label {
                L10n.Common.open
            } icon: {
                Image(systemName: "music.note")
            }
        }
        Button { onOpenInNewWindow(item) } label: {
            Label {
                Text("library.open.newWindow", bundle: .module)
            } icon: {
                Image(systemName: "macwindow")
            }
        }
    }
    #endif

    private func toggleSelection(_ id: ScoreItemID) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }
}

#if DEBUG
private enum PlaylistDetailViewPreview {
    static let items: [ScoreItem] = (1 ... 4).map { idx in
        ScoreItem(
            title: "Score \(idx)",
            composer: "Composer \(idx)",
            instrumentationSummary: "Piano",
            localFileName: "\(UUID().uuidString).musicxml",
            contentHash: String(repeating: "0", count: 64),
            sizeBytes: 1024,
            lengthBeats: 256,
            defaultTempoBpm: 120,
            primaryKey: nil,
            addedAt: Date(),
            lastOpenedAt: nil,
            tagIDs: [],
            isFavorite: false,
        )
    }
}

private struct PlaylistDetailViewPreviewHost: View {
    let playlistName: String
    let items: [ScoreItem]
    @State private var selectedIDs: Set<ScoreItemID> = []

    var body: some View {
        NavigationStack {
            PlaylistDetailView(
                playlistName: playlistName,
                items: items,
                onOpen: { _ in },
                onOpenInNewWindow: { _ in },
                onMove: { _, _ in },
                onRemoveFromPlaylist: { (_: ScoreItem) in },
                onRename: { _ in },
                onDelete: {},
                selectedIDs: $selectedIDs,
                availableShareFormats: [],
                onBulkShare: { _ in },
                onBulkAddToPlaylist: {},
                onBulkEditTags: {},
                onBulkFavorite: {},
                allBulkFavorited: false,
                onBulkDelete: {},
            )
        }
    }
}

#Preview("Filled") {
    PlaylistDetailViewPreviewHost(
        playlistName: "Daily warm-up",
        items: PlaylistDetailViewPreview.items,
    )
}

#Preview("Empty") {
    PlaylistDetailViewPreviewHost(playlistName: "Empty Set", items: [])
}
#endif
