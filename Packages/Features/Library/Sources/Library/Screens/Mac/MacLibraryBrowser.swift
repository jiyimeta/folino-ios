#if os(macOS)
import Domain
import SwiftUI
import UniformTypeIdentifiers

/// The Mac library browser window's whole content: `MacLibrarySidebar` (Task 3) in the sidebar column, the selected
/// source's scores in the detail column.
///
/// **One `NavigationSplitView`, no `NavigationStack` anywhere in either column.** `MacLibrarySidebar`'s doc comment
/// and `RowOpenAffordance.swift` record the two measurements this whole arrangement exists to respect: a
/// `NavigationStack` pushed inside a `NavigationSplitView` sidebar renders bottom-anchored on macOS 26.4.1, and any
/// SwiftUI tap gesture on a `List(selection:)` row leaves the selection permanently empty. Every screen `content`
/// switches into below is a leaf that carries neither.
///
/// `App/Mac` (Task 6) is the only consumer, which is why `MacLibraryBrowser` — and only this type — is `public`.
public struct MacLibraryBrowser: View {
    let viewModel: LibraryViewModel
    let onOpenScore: (ScoreItem) -> Void
    let onOpenScoreInNewWindow: (ScoreItem) -> Void
    let onOpenInPlaylist: (ScoreItem, PlaylistID) -> Void

    @State private var selection: LibrarySource? = .recents
    /// Recents has no `ScoreListViewModel.Source` case of its own — see this file's `content` doc comment — so this
    /// screen builds its own `ScoreListScreen` on an `.all`-sourced view model and forces its sort, the same way
    /// `AllScoresScreen` builds one in its own `init`. Held here (not recreated per `body`) so the view model's
    /// state — search text, an in-pane sort change — survives switching to another source and back.
    @State private var recentsListViewModel: ScoreListViewModel

    /// Driven by the row menu's "Edit Tags" / "Add to Playlist" actions inside whichever leaf screen `content` is
    /// showing — mirrors `LibraryRootScreen`'s own `editTagsTarget` / `addToPlaylistTarget`, since none of the leaf
    /// screens present these sheets themselves.
    @State private var editTagsTarget: ScoreItem?
    @State private var addToPlaylistTarget: ScoreItem?

    public init(
        viewModel: LibraryViewModel,
        onOpenScore: @escaping (ScoreItem) -> Void,
        onOpenScoreInNewWindow: @escaping (ScoreItem) -> Void,
        onOpenInPlaylist: @escaping (ScoreItem, PlaylistID) -> Void,
    ) {
        self.viewModel = viewModel
        self.onOpenScore = onOpenScore
        self.onOpenScoreInNewWindow = onOpenScoreInNewWindow
        self.onOpenInPlaylist = onOpenInPlaylist
        let recentsListViewModel = ScoreListViewModel(
            source: .all, repository: viewModel.repository, analytics: viewModel.analytics,
        )
        recentsListViewModel.sort = .lastOpenedDesc
        _recentsListViewModel = State(wrappedValue: recentsListViewModel)
    }

    public var body: some View {
        NavigationSplitView {
            MacLibrarySidebar(viewModel: viewModel, selection: $selection)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            content
        }
        .frame(minWidth: 820, minHeight: 520)
        .sheet(item: $editTagsTarget) { item in
            EditTagsScreen(scoreItem: item, library: viewModel)
        }
        .sheet(item: $addToPlaylistTarget) { item in
            AddToPlaylistScreen(scoreItem: item, library: viewModel)
        }
        // Moved from `MacShellView.sidebar` — the library, not the reader, is what a dropped file belongs to, and the
        // library is this window now. Same body as the one it came from: filter to importable files, start each
        // import, and report `true` only when at least one file qualified.
        .dropDestination(for: URL.self) { urls, _ in
            let importable = urls.filter(isImportableScoreURL)
            guard !importable.isEmpty else { return false }
            Task {
                for url in importable {
                    await viewModel.startImport(from: url)
                }
            }
            return true
        }
    }

    /// The selected source's screen. Every case is one of the existing leaf screens (Task 2 already gave each of
    /// them the `onOpenInNewWindow` closure this window needs), except `.recents`: `ScoreListViewModel.Source` has
    /// no case for "opened scores only," so there is no existing screen that filters to them, and adding one is out
    /// of scope here — see `recentsListViewModel`. `.tag` / `.playlist` are keyed by `.id(_:)` because the switch's
    /// branch position alone does not change when only the associated `TagID` / `PlaylistID` changes, and without it
    /// SwiftUI would reuse the previous screen's `@State`-held `ScoreListViewModel` — pointed at the old tag/playlist
    /// — instead of building a fresh one for the new selection.
    @ViewBuilder
    private var content: some View {
        switch selection {
        case .recents:
            ScoreListScreen(
                viewModel: recentsListViewModel,
                library: viewModel,
                onOpen: onOpenScore,
                onOpenInNewWindow: onOpenScoreInNewWindow,
                onEditTags: { editTagsTarget = $0 },
                onAddToPlaylist: { addToPlaylistTarget = $0 },
            )
            .navigationTitle(Text("library.recentlyOpened", bundle: .module))
        case .allScores:
            AllScoresScreen(
                library: viewModel,
                onOpen: onOpenScore,
                onOpenInNewWindow: onOpenScoreInNewWindow,
                onEditTags: { editTagsTarget = $0 },
                onAddToPlaylist: { addToPlaylistTarget = $0 },
            )
        case .favorites:
            FavoritesScreen(
                library: viewModel,
                onOpen: onOpenScore,
                onOpenInNewWindow: onOpenScoreInNewWindow,
                onEditTags: { editTagsTarget = $0 },
                onAddToPlaylist: { addToPlaylistTarget = $0 },
            )
        case let .playlist(id):
            if let playlist = viewModel.repository.playlists.first(where: { $0.id == id }) {
                PlaylistDetailScreen(
                    playlist: playlist,
                    library: viewModel,
                    onOpenInPlaylist: onOpenInPlaylist,
                    onPlaylistDeleted: { selection = .allScores },
                )
                .id(id)
            } else {
                notFound(titleKey: "library.playlist.notFound", systemImage: "music.note.list")
            }
        case let .tag(id):
            if let tag = viewModel.repository.tags.first(where: { $0.id == id }) {
                TagDetailScreen(
                    tag: tag,
                    library: viewModel,
                    onOpen: onOpenScore,
                    onOpenInNewWindow: onOpenScoreInNewWindow,
                    onEditTags: { editTagsTarget = $0 },
                    onAddToPlaylist: { addToPlaylistTarget = $0 },
                    onTagDeleted: { selection = .allScores },
                )
                .id(id)
            } else {
                notFound(titleKey: "library.tag.notFound", systemImage: "tag.slash")
            }
        case .recentlyDeleted:
            RecentlyDeletedScreen(library: viewModel, onOpen: onOpenScore, onOpenInNewWindow: onOpenScoreInNewWindow)
        case nil:
            ContentUnavailableView {
                Label {
                    Text("library.browser.noSource", bundle: .module)
                } icon: {
                    Image(systemName: "sidebar.left")
                }
            }
        }
    }

    private func notFound(titleKey: LocalizedStringKey, systemImage: String) -> some View {
        ContentUnavailableView {
            Label {
                Text(titleKey, bundle: .module)
            } icon: {
                Image(systemName: systemImage)
            }
        }
    }
}

/// Mirrors `ScoreImportContentTypes.isImportable` in `App/Mac/MacCommands.swift` — Library cannot import App, so the
/// same filename-extension check against `ScoreFileTypes.allowed` is duplicated here rather than shared.
private func isImportableScoreURL(_ url: URL) -> Bool {
    guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
    return ScoreFileTypes.allowed.contains { type.conforms(to: $0) }
}

#if DEBUG
#Preview("Browser") {
    MacLibraryBrowser(
        viewModel: previewMacLibrarySidebarViewModel(),
        onOpenScore: { _ in },
        onOpenScoreInNewWindow: { _ in },
        onOpenInPlaylist: { _, _ in },
    )
    .frame(width: 1000, height: 640)
}
#endif
#endif
