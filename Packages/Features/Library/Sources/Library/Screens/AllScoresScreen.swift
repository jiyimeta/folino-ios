import Domain
import SwiftUI

struct AllScoresScreen: View {
    let library: LibraryViewModel
    let onOpen: (ScoreItem) -> Void
    /// **macOS only**, in effect — see `ScoreListView.onOpenInNewWindow`.
    let onOpenInNewWindow: (ScoreItem) -> Void
    let onEditTags: (ScoreItem) -> Void
    let onAddToPlaylist: (ScoreItem) -> Void

    @State private var listVM: ScoreListViewModel

    init(
        library: LibraryViewModel,
        onOpen: @escaping (ScoreItem) -> Void,
        onOpenInNewWindow: @escaping (ScoreItem) -> Void,
        onEditTags: @escaping (ScoreItem) -> Void,
        onAddToPlaylist: @escaping (ScoreItem) -> Void,
    ) {
        self.library = library
        self.onOpen = onOpen
        self.onOpenInNewWindow = onOpenInNewWindow
        self.onEditTags = onEditTags
        self.onAddToPlaylist = onAddToPlaylist
        _listVM = State(
            wrappedValue: ScoreListViewModel(
                source: .all, repository: library.repository, analytics: library.analytics,
            ),
        )
    }

    var body: some View {
        ScoreListScreen(
            viewModel: listVM,
            library: library,
            onOpen: onOpen,
            onOpenInNewWindow: onOpenInNewWindow,
            onEditTags: onEditTags,
            onAddToPlaylist: onAddToPlaylist,
        )
        .navigationTitle(Text("library.allScores", bundle: .module))
    }
}
