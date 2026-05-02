import Domain
import SwiftUI

struct TagDetailView: View {
    let tag: Tag
    let library: LibraryViewModel
    let onOpen: (ScoreItem) -> Void
    let onEditTags: (ScoreItem) -> Void
    let onAddToPlaylist: (ScoreItem) -> Void
    let onTagDeleted: () -> Void

    @State private var listVM: ScoreListViewModel
    @State private var isRenaming = false
    @State private var renameText: String = ""
    @State private var isConfirmingDelete = false

    init(
        tag: Tag,
        library: LibraryViewModel,
        onOpen: @escaping (ScoreItem) -> Void,
        onEditTags: @escaping (ScoreItem) -> Void,
        onAddToPlaylist: @escaping (ScoreItem) -> Void,
        onTagDeleted: @escaping () -> Void
    ) {
        self.tag = tag
        self.library = library
        self.onOpen = onOpen
        self.onEditTags = onEditTags
        self.onAddToPlaylist = onAddToPlaylist
        self.onTagDeleted = onTagDeleted
        _listVM = State(
            wrappedValue: ScoreListViewModel(source: .taggedWith(tag.id), repository: library.repository)
        )
    }

    var body: some View {
        ScoreListView(
            viewModel: listVM,
            library: library,
            onOpen: onOpen,
            onEditTags: onEditTags,
            onAddToPlaylist: onAddToPlaylist
        )
        .navigationTitle(tag.name)
        .toolbar { editMenuToolbar }
        .alert("Rename Tag", isPresented: $isRenaming) {
            TextField("Tag name", text: $renameText)
            Button("Save") { Task { await commitRename() } }
            Button("Cancel", role: .cancel) {}
        }
        .alert(
            "Delete \"\(tag.name)\"?",
            isPresented: $isConfirmingDelete
        ) {
            Button("Delete", role: .destructive) {
                Task { await commitDelete() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Scores keep their data; only the tag and its assignments are removed.")
        }
    }

    @ToolbarContentBuilder
    private var editMenuToolbar: some ToolbarContent {
        #if os(iOS)
            ToolbarItem(placement: .topBarTrailing) { editMenu }
        #else
            ToolbarItem(placement: .automatic) { editMenu }
        #endif
    }

    private var editMenu: some View {
        Menu {
            Button {
                renameText = tag.name
                isRenaming = true
            } label: { Label("Rename…", systemImage: "pencil") }
            Button(role: .destructive) {
                isConfirmingDelete = true
            } label: { Label("Delete Tag", systemImage: "trash") }
        } label: {
            Image(systemName: "ellipsis.circle")
                .accessibilityLabel("Edit Tag")
        }
    }

    private func commitRename() async {
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != tag.name else { return }
        var updated = tag
        updated.name = trimmed
        do {
            try await library.repository.saveTag(updated)
        } catch {
            library.errorAlertMessage = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    private func commitDelete() async {
        do {
            try await library.repository.deleteTag(id: tag.id)
            onTagDeleted()
        } catch {
            library.errorAlertMessage = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }
}
