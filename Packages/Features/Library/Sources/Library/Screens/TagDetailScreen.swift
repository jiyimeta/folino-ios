import Domain
import SwiftUI
import UtilityCore

struct TagDetailScreen: View {
    let tag: Tag
    let library: LibraryViewModel
    let onOpen: (ScoreItem) -> Void
    /// **macOS only**, in effect — see `ScoreListView.onOpenInNewWindow`.
    let onOpenInNewWindow: (ScoreItem) -> Void
    let onEditTags: (ScoreItem) -> Void
    let onAddToPlaylist: (ScoreItem) -> Void
    let onTagDeleted: () -> Void

    @State private var listVM: ScoreListViewModel

    init(
        tag: Tag,
        library: LibraryViewModel,
        onOpen: @escaping (ScoreItem) -> Void,
        onOpenInNewWindow: @escaping (ScoreItem) -> Void,
        onEditTags: @escaping (ScoreItem) -> Void,
        onAddToPlaylist: @escaping (ScoreItem) -> Void,
        onTagDeleted: @escaping () -> Void,
    ) {
        self.tag = tag
        self.library = library
        self.onOpen = onOpen
        self.onOpenInNewWindow = onOpenInNewWindow
        self.onEditTags = onEditTags
        self.onAddToPlaylist = onAddToPlaylist
        self.onTagDeleted = onTagDeleted
        _listVM = State(
            wrappedValue: ScoreListViewModel(
                source: .taggedWith(tag.id), repository: library.repository, analytics: library.analytics,
            ),
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
                onOpenInNewWindow: onOpenInNewWindow,
                onEditTags: onEditTags,
                onAddToPlaylist: onAddToPlaylist,
            )
        }
        .onAppear { library.analytics.logScreen(.tagDetail) }
    }

    private func commitRename(_ newName: String) async {
        var updated = tag
        updated.name = newName
        do {
            try await library.repository.saveTag(updated)
            library.analytics.log(.tagRenamed(source: .tag))
        } catch {
            library.currentError = error
        }
    }

    private func commitDelete() async {
        do {
            try await library.repository.deleteTag(id: tag.id)
            library.analytics.log(.tagDeleted(source: .tag))
            onTagDeleted()
        } catch {
            library.currentError = error
        }
    }
}
