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
    let onBulkDelete: () -> Void

    #if os(iOS)
        @State private var editMode: EditMode = .inactive
    #endif

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
                                if isEditing {
                                    toggleSelection(item.id)
                                } else {
                                    onOpen(item)
                                }
                            }
                            .tag(item.id)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    onRemoveFromPlaylist(item)
                                } label: {
                                    Label {
                                        Text("library.playlist.removeScore.action", bundle: .module)
                                    } icon: {
                                        Image(systemName: "minus.circle")
                                    }
                                }
                            }
                    }
                    .onMove(perform: onMove)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            #if os(iOS)
                if editMode.isEditing {
                    BulkActionBar(
                        selectionCount: selectedIDs.count,
                        availableShareFormats: availableShareFormats,
                        onShare: onBulkShare,
                        onAddToPlaylist: onBulkAddToPlaylist,
                        onEditTags: onBulkEditTags,
                        onDelete: onBulkDelete
                    )
                }
            #endif
        }
        .navigationTitle(playlistName)
        #if os(iOS)
            .environment(\.editMode, $editMode)
            .toolbar {
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
                        if editMode.isEditing {
                            L10n.Common.cancel
                                .transition(.identity)
                        } else {
                            L10n.Common.select
                                .transition(.identity)
                        }
                    }
                }
            }
        #endif
            .manageEntityToolbar(
                    entityName: playlistName,
                    copy: .playlist,
                    onRename: onRename,
                    onDelete: onDelete
                )
    }

    private var isEditing: Bool {
        #if os(iOS)
            return editMode.isEditing
        #else
            return false
        #endif
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
                isFavorite: false
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
                    onBulkDelete: {}
                )
            }
        }
    }

    #Preview("Filled") {
        PlaylistDetailViewPreviewHost(
            playlistName: "Daily warm-up",
            items: PlaylistDetailViewPreview.items
        )
    }

    #Preview("Empty") {
        PlaylistDetailViewPreviewHost(playlistName: "Empty Set", items: [])
    }
#endif
