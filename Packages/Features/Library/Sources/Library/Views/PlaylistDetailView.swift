import Domain
import SwiftUI
import UtilityUI

struct PlaylistDetailView: View {
    let playlistName: String
    let items: [ScoreItem]
    let onOpen: (ScoreItem) -> Void
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
                            .onTapGesture {
                                if isSelecting {
                                    toggleSelection(item.id)
                                } else {
                                    onOpen(item)
                                }
                            }
                            .tag(item.id)
                            // No `role: .destructive` — see `LibraryRootScreen.sectionRow`.
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
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
                    }
                    .onMove(perform: onMove)
                }
            }
        }
        // PARITY(macos): bulk-selection chrome — iOS needs an explicit Select mode because a touch list cannot
        //   distinguish a tap-to-open from a tap-to-select. AppKit's List multi-selects natively with ⌘/⇧-click, so
        //   the Mac has no mode and reaches the same bulk actions from the selection's context menu (and, in
        //   sub-project Ⅳ, the menu bar).
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
