import Domain
import SwiftUI

struct PlaylistDetailView: View {
    let playlistName: String
    let items: [ScoreItem]
    let onOpen: (ScoreItem) -> Void
    let onMove: (IndexSet, Int) -> Void
    let onRemoveFromPlaylist: (IndexSet) -> Void
    let onRename: (String) -> Void
    let onDelete: () -> Void
    @Binding var selectedIDs: Set<ScoreItemID>
    let onBulkAddToPlaylist: () -> Void
    let onBulkEditTags: () -> Void
    let onBulkDelete: () -> Void

    #if os(iOS)
        @State private var editMode: EditMode = .inactive
    #endif
    @State private var isRenaming = false
    @State private var renameText: String = ""
    @State private var isConfirmingDelete = false

    var body: some View {
        Group {
            if items.isEmpty {
                ContentUnavailableView {
                    Label {
                        Text("No Scores in This Playlist", bundle: .module)
                    } icon: {
                        Image(systemName: "music.note.list")
                    }
                } description: {
                    Text("Add scores from the context menu of any score row.", bundle: .module)
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
                    }
                    .onMove(perform: onMove)
                    .onDelete(perform: onRemoveFromPlaylist)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            #if os(iOS)
                if editMode.isEditing {
                    BulkActionBar(
                        selectionCount: selectedIDs.count,
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
        #endif
            .toolbar { editToolbar }
            .alert(Text("Rename Playlist", bundle: .module), isPresented: $isRenaming) {
                TextField(text: $renameText) { Text("Playlist name", bundle: .module) }
                Button {
                    let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty, trimmed != playlistName else { return }
                    onRename(trimmed)
                } label: { Text("Save", bundle: .module) }
                Button(role: .cancel) {} label: { Text("Cancel", bundle: .module) }
            }
            .alert(
                Text("Delete \"\(playlistName)\"?", bundle: .module),
                isPresented: $isConfirmingDelete
            ) {
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Text("Delete", bundle: .module)
                }
                Button(role: .cancel) {} label: { Text("Cancel", bundle: .module) }
            } message: {
                Text("Scores keep their data; only the playlist and its order are removed.", bundle: .module)
            }
    }

    @ToolbarContentBuilder
    private var editToolbar: some ToolbarContent {
        #if os(iOS)
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
                    Text(editMode.isEditing ? "Cancel" : "Select", bundle: .module)
                }
            }
            ToolbarItem(placement: .topBarLeading) { manageMenu }
        #else
            ToolbarItem(placement: .automatic) { manageMenu }
        #endif
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

    private var manageMenu: some View {
        Menu {
            Button {
                renameText = playlistName
                isRenaming = true
            } label: {
                Label {
                    Text("Rename…", bundle: .module)
                } icon: {
                    Image(systemName: "pencil")
                }
            }
            Button(role: .destructive) {
                isConfirmingDelete = true
            } label: {
                Label {
                    Text("Delete Playlist", bundle: .module)
                } icon: {
                    Image(systemName: "trash")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .accessibilityLabel(Text("Edit Playlist", bundle: .module))
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
                    onRemoveFromPlaylist: { _ in },
                    onRename: { _ in },
                    onDelete: {},
                    selectedIDs: $selectedIDs,
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
