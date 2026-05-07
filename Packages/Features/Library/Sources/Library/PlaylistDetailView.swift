import Domain
import SwiftUI

struct PlaylistDetailView: View {
    let playlist: Playlist
    let library: LibraryViewModel
    let onOpen: (ScoreItem) -> Void
    let onPlaylistDeleted: () -> Void

    #if os(iOS)
        @State private var editMode: EditMode = .inactive
    #endif
    @State private var isRenaming = false
    @State private var renameText: String = ""
    @State private var isConfirmingDelete = false

    var body: some View {
        Group {
            if orderedItems.isEmpty {
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
                List {
                    ForEach(orderedItems) { item in
                        ScoreRow(scoreItem: item)
                            .contentShape(Rectangle())
                            .onTapGesture { onOpen(item) }
                    }
                    .onMove(perform: move)
                    .onDelete(perform: removeFromPlaylist)
                }
            }
        }
        .navigationTitle(playlist.name)
        #if os(iOS)
            .environment(\.editMode, $editMode)
        #endif
            .toolbar { editToolbar }
            .alert(Text("Rename Playlist", bundle: .module), isPresented: $isRenaming) {
                TextField(text: $renameText) { Text("Playlist name", bundle: .module) }
                Button { Task { await commitRename() } } label: { Text("Save", bundle: .module) }
                Button(role: .cancel) {} label: { Text("Cancel", bundle: .module) }
            }
            .alert(
                Text("Delete \"\(playlist.name)\"?", bundle: .module),
                isPresented: $isConfirmingDelete
            ) {
                Button(role: .destructive) {
                    Task { await commitDelete() }
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
            ToolbarItem(placement: .topBarTrailing) { EditButton() }
            ToolbarItem(placement: .topBarLeading) { manageMenu }
        #else
            ToolbarItem(placement: .automatic) { manageMenu }
        #endif
    }

    private var manageMenu: some View {
        Menu {
            Button {
                renameText = playlist.name
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
            Image(systemName: "ellipsis.circle")
                .accessibilityLabel(Text("Edit Playlist", bundle: .module))
        }
    }

    private var orderedItems: [ScoreItem] {
        let lookup = Dictionary(uniqueKeysWithValues: library.repository.scoreItems.map { ($0.id, $0) })
        return playlist.orderedScoreItemIDs.compactMap { lookup[$0] }
    }

    private func move(from offsets: IndexSet, to destination: Int) {
        var ids = playlist.orderedScoreItemIDs
        ids.move(fromOffsets: offsets, toOffset: destination)
        var updated = playlist
        updated.orderedScoreItemIDs = ids
        Task {
            do {
                try await library.repository.savePlaylist(updated)
            } catch {
                library.errorAlertMessage = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
    }

    private func removeFromPlaylist(at offsets: IndexSet) {
        let removedIDs = offsets.map { orderedItems[$0].id }
        var updated = playlist
        updated.orderedScoreItemIDs.removeAll { removedIDs.contains($0) }
        Task {
            do {
                try await library.repository.savePlaylist(updated)
            } catch {
                library.errorAlertMessage = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
    }

    private func commitRename() async {
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != playlist.name else { return }
        var updated = playlist
        updated.name = trimmed
        do {
            try await library.repository.savePlaylist(updated)
        } catch {
            library.errorAlertMessage = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    private func commitDelete() async {
        do {
            try await library.repository.deletePlaylist(id: playlist.id)
            onPlaylistDeleted()
        } catch {
            library.errorAlertMessage = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }
}
