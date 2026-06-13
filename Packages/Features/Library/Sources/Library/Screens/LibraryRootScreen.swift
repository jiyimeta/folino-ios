import Domain
import ScoreUI
import SwiftUI
import UniformTypeIdentifiers
import UtilityUI

@MainActor
public struct LibraryRootScreen<LicenseContent: View, ReaderContent: View, LeadingToolbar: View>: View {
    @Bindable var viewModel: LibraryViewModel
    @Binding private var path: NavigationPath
    private let onOpenScore: (ScoreItem) -> Void
    private let readerDestination: (ScoreItem) -> ReaderContent
    private let playlistReaderDestination: (PlaylistReaderRoute) -> ReaderContent
    private let onOpenInPlaylist: (ScoreItem, PlaylistID) -> Void
    private let licenseContent: () -> LicenseContent
    private let leadingToolbarItem: () -> LeadingToolbar

    @State private var editTagsTarget: ScoreItem?
    @State private var addToPlaylistTarget: ScoreItem?

    @State private var isCreatingPlaylist = false
    @State private var newPlaylistName = ""
    @State private var isCreatingTag = false
    @State private var newTagName = ""

    @State private var pendingDeletePlaylist: Playlist?
    @State private var pendingDeleteTag: Tag?
    @State private var editInfoTarget: ScoreItem?

    /// Derived from `repository.scoreItems`, recomputed only when that array changes (via `body`'s `onChange`) instead
    /// of on every body evaluation — navigation pushes and tag/playlist edits re-run `rootList` but must not re-run the
    /// recently-opened sort or the favorites count.
    @State private var recentlyOpened: [ScoreItem] = []
    @State private var favoriteCount = 0

    public init(
        viewModel: LibraryViewModel,
        path: Binding<NavigationPath>,
        onOpenScore: @escaping (ScoreItem) -> Void,
        @ViewBuilder readerDestination: @escaping (ScoreItem) -> ReaderContent,
        @ViewBuilder playlistReaderDestination: @escaping (PlaylistReaderRoute) -> ReaderContent,
        onOpenInPlaylist: @escaping (ScoreItem, PlaylistID) -> Void,
        @ViewBuilder licenseContent: @escaping () -> LicenseContent,
        @ViewBuilder leadingToolbarItem: @escaping () -> LeadingToolbar = { EmptyView() },
    ) {
        self.viewModel = viewModel
        _path = path
        self.onOpenScore = onOpenScore
        self.readerDestination = readerDestination
        self.playlistReaderDestination = playlistReaderDestination
        self.onOpenInPlaylist = onOpenInPlaylist
        self.licenseContent = licenseContent
        self.leadingToolbarItem = leadingToolbarItem
    }

    public var body: some View {
        NavigationStack(path: $path) {
            rootList
                .navigationTitle(Text("library.title", bundle: .module))
                .toolbar { leadingToolbar }
                .toolbar { importToolbar }
                .fileImporter(
                    isPresented: $viewModel.isFileImporterPresented,
                    allowedContentTypes: ScoreFileTypes.allowed,
                    allowsMultipleSelection: false,
                ) { result in
                    switch result {
                    case let .success(urls):
                        guard let url = urls.first else { return }
                        Task { await viewModel.startImport(from: url) }
                    case let .failure(error):
                        viewModel.currentError = error
                    }
                }
                .navigationDestination(for: LibraryRoute.self) { route in
                    libraryRootDestination(
                        for: route,
                        viewModel: viewModel,
                        onOpenScore: onOpenScore,
                        onEditTags: { editTagsTarget = $0 },
                        onAddToPlaylist: { addToPlaylistTarget = $0 },
                        onOpenInPlaylist: onOpenInPlaylist,
                    )
                }
                .navigationDestination(for: ScoreItem.self) { item in
                    readerDestination(item)
                }
                .navigationDestination(for: PlaylistReaderRoute.self) { route in
                    playlistReaderDestination(route)
                }
        }
        .onChange(of: viewModel.repository.scoreItems, initial: true) { _, items in
            recentlyOpened = items.mostRecentlyOpened(limit: 5)
            favoriteCount = items.reduce(0) { $0 + ($1.isFavorite ? 1 : 0) }
        }
        .editScoreInfoSheet(viewModel: viewModel, target: $editInfoTarget)
        .libraryRootDeleteAlerts(
            viewModel: viewModel,
            pendingDeletePlaylist: $pendingDeletePlaylist,
            pendingDeleteTag: $pendingDeleteTag,
        )
        .libraryRootPresentations(
            viewModel: viewModel,
            editTagsTarget: $editTagsTarget,
            addToPlaylistTarget: $addToPlaylistTarget,
            isCreatingPlaylist: $isCreatingPlaylist,
            newPlaylistName: $newPlaylistName,
            isCreatingTag: $isCreatingTag,
            newTagName: $newTagName,
        )
    }

    @ToolbarContentBuilder
    private var importToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) { addMenu }
    }

    @ToolbarContentBuilder
    private var leadingToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) { leadingToolbarItem() }
    }

    private var addMenu: some View {
        Menu {
            Button {
                viewModel.isFileImporterPresented = true
            } label: {
                Label {
                    Text("library.import.title", bundle: .module)
                } icon: {
                    Image(systemName: "square.and.arrow.down")
                }
            }
            Button {
                newPlaylistName = ""
                isCreatingPlaylist = true
            } label: {
                Label {
                    Text("library.playlist.create.title", bundle: .module)
                } icon: {
                    Image(systemName: "music.note.list")
                }
            }
            Button {
                newTagName = ""
                isCreatingTag = true
            } label: {
                Label {
                    Text("library.tag.create.title", bundle: .module)
                } icon: {
                    Image(systemName: "tag")
                }
            }
        } label: {
            Image(systemName: "plus").accessibilityLabel(L10n.Common.add)
        }
    }

    @ViewBuilder
    private var rootList: some View {
        let items = viewModel.repository.scoreItems

        if items.isEmpty
            && viewModel.repository.tags.isEmpty
            && viewModel.repository.playlists.isEmpty
            && viewModel.repository.deletedScoreItems.isEmpty
        {
            ContentUnavailableView {
                Label {
                    Text("library.allScores.empty.title", bundle: .module)
                } icon: {
                    Image(systemName: "music.note")
                }
            } description: {
                Text("library.allScores.empty.hint", bundle: .module)
            }
        } else {
            List {
                LibraryRootBrowseSection(
                    scoreCount: items.count,
                    favoriteCount: favoriteCount,
                    trashCount: viewModel.repository.deletedScoreItems.count,
                )
                LibraryRootPlaylistsSection(
                    allPlaylists: viewModel.repository.playlists,
                    scoreItems: items,
                    onRequestDelete: { pendingDeletePlaylist = $0 },
                )
                LibraryRootTagsSection(
                    allTags: viewModel.repository.tags,
                    scoreItems: items,
                    onRequestDelete: { pendingDeleteTag = $0 },
                )
                LibraryRootRecentsSection(
                    recents: recentlyOpened,
                    viewModel: viewModel,
                    onOpenScore: onOpenScore,
                    editInfoTarget: $editInfoTarget,
                    editTagsTarget: $editTagsTarget,
                    addToPlaylistTarget: $addToPlaylistTarget,
                )
            }
            .listStyle(.sidebar)
        }
    }
}

enum ScoreFileTypes {
    /// Each specific UTI comes from whichever app on the device owns the extension's registration; parent fallbacks
    /// (`.xml`, `.zip`, `.midi`) cover cloud providers that hand us generic UTIs and devices where a sibling app's UTI
    /// doesn't conform to ours. `LiveScoreFileImporter.prepareImport` rejects unsupported files by filename extension.
    static let allowed: [UTType] = {
        let specific = ["mscx", "mscz", "musicxml", "mxl"]
            .compactMap { UTType(filenameExtension: $0) }
        return specific + [.xml, .zip, .midi]
    }()
}
