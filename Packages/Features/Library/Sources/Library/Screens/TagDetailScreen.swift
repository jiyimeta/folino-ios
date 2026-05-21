import Domain
import LibraryLogic
import SwiftUI

struct TagDetailScreen: View {
    let tag: Tag
    let library: LibraryStore
    let onOpen: (ScoreItem) -> Void
    let onEditTags: (ScoreItem) -> Void
    let onAddToPlaylist: (ScoreItem) -> Void
    let onTagDeleted: () -> Void

    @State private var listVM: ScoreListStore

    init(
        tag: Tag,
        library: LibraryStore,
        onOpen: @escaping (ScoreItem) -> Void,
        onEditTags: @escaping (ScoreItem) -> Void,
        onAddToPlaylist: @escaping (ScoreItem) -> Void,
        onTagDeleted: @escaping () -> Void,
    ) {
        self.tag = tag
        self.library = library
        self.onOpen = onOpen
        self.onEditTags = onEditTags
        self.onAddToPlaylist = onAddToPlaylist
        self.onTagDeleted = onTagDeleted
        _listVM = State(
            wrappedValue: library.makeScoreListStore(source: .taggedWith(tag.id)),
        )
    }

    var body: some View {
        TagDetailView(
            tagName: tag.name,
            onRename: { newName in Task { await commitRename(newName) } },
            onDelete: { Task { await commitDelete() } },
        ) {
            ScoreListScreen(
                viewModel: listVM,
                library: library,
                onOpen: onOpen,
                onEditTags: onEditTags,
                onAddToPlaylist: onAddToPlaylist,
            )
        }
    }

    private func commitRename(_ newName: String) async {
        var updated = tag
        updated.name = newName
        await library.saveTag(updated)
    }

    private func commitDelete() async {
        await library.deleteTag(tag)
        onTagDeleted()
    }
}
