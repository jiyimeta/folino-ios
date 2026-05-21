import Domain
import LibraryLogic
import SwiftUI

struct FavoritesScreen: View {
    let library: LibraryStore
    let onOpen: (ScoreItem) -> Void
    let onEditTags: (ScoreItem) -> Void
    let onAddToPlaylist: (ScoreItem) -> Void

    @State private var listVM: ScoreListStore

    init(
        library: LibraryStore,
        onOpen: @escaping (ScoreItem) -> Void,
        onEditTags: @escaping (ScoreItem) -> Void,
        onAddToPlaylist: @escaping (ScoreItem) -> Void,
    ) {
        self.library = library
        self.onOpen = onOpen
        self.onEditTags = onEditTags
        self.onAddToPlaylist = onAddToPlaylist
        _listVM = State(
            wrappedValue: ScoreListStore(source: .favorites, repository: library.repository),
        )
    }

    var body: some View {
        ScoreListScreen(
            viewModel: listVM,
            library: library,
            onOpen: onOpen,
            onEditTags: onEditTags,
            onAddToPlaylist: onAddToPlaylist,
        )
        .navigationTitle(Text("library.favorites", bundle: .module))
    }
}
