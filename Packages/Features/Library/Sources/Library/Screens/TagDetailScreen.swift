import Domain
import SwiftUI

struct TagDetailScreen: View {
    let tag: Tag
    let library: LibraryViewModel
    let onOpen: (ScoreItem) -> Void
    let onEditTags: (ScoreItem) -> Void
    let onAddToPlaylist: (ScoreItem) -> Void
    let onTagDeleted: () -> Void

    @State private var listVM: ScoreListViewModel

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
        TagDetailView(
            tagName: tag.name,
            onRename: { newName in Task { await commitRename(newName) } },
            onDelete: { Task { await commitDelete() } }
        ) {
            ScoreListScreen(
                viewModel: listVM,
                library: library,
                onOpen: onOpen,
                onEditTags: onEditTags,
                onAddToPlaylist: onAddToPlaylist
            )
        }
    }

    private func commitRename(_ newName: String) async {
        var updated = tag
        updated.name = newName
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
