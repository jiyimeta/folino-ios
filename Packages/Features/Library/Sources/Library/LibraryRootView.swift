import Domain
import SwiftUI
import UniformTypeIdentifiers

@MainActor
public struct LibraryRootView<LicenseContent: View>: View {
    @State private var viewModel: LibraryViewModel
    private let onOpenScore: (ScoreItem) -> Void
    private let licenseContent: () -> LicenseContent

    @State private var editTagsTarget: ScoreItem?
    @State private var addToPlaylistTarget: ScoreItem?

    public init(
        repository: any ScoreLibraryRepository,
        importer: any ScoreFileImporter,
        gateway: any ScoreFileGateway,
        onOpenScore: @escaping (ScoreItem) -> Void,
        @ViewBuilder licenseContent: @escaping () -> LicenseContent
    ) {
        _viewModel = State(
            wrappedValue: LibraryViewModel(
                repository: repository, importer: importer, gateway: gateway
            )
        )
        self.onOpenScore = onOpenScore
        self.licenseContent = licenseContent
    }

    public var body: some View {
        NavigationStack {
            rootList
                .navigationTitle("Library")
                .toolbar { importToolbar }
                .fileImporter(
                    isPresented: $viewModel.isFileImporterPresented,
                    allowedContentTypes: ScoreFileTypes.allowed,
                    allowsMultipleSelection: false
                ) { result in
                    switch result {
                    case let .success(urls):
                        guard let url = urls.first else { return }
                        Task { await viewModel.startImport(from: url) }
                    case let .failure(error):
                        viewModel.errorAlertMessage = error.localizedDescription
                    }
                }
                .navigationDestination(for: LibraryRoute.self) { route in
                    destination(for: route)
                }
        }
        .sheet(item: $editTagsTarget) { item in
            EditTagsSheet(scoreItem: item, library: viewModel)
        }
        .sheet(item: $addToPlaylistTarget) { item in
            AddToPlaylistSheet(scoreItem: item, library: viewModel)
        }
        .alert(
            "Library",
            isPresented: errorAlertBinding,
            presenting: viewModel.errorAlertMessage
        ) { _ in
            Button("OK") { viewModel.errorAlertMessage = nil }
        } message: { msg in
            Text(msg)
        }
    }

    @ToolbarContentBuilder
    private var importToolbar: some ToolbarContent {
        #if os(iOS)
            ToolbarItem(placement: .topBarTrailing) { importButton }
        #else
            ToolbarItem(placement: .automatic) { importButton }
        #endif
    }

    private var importButton: some View {
        Button {
            viewModel.isFileImporterPresented = true
        } label: {
            Image(systemName: "plus").accessibilityLabel("Import Score")
        }
    }

    @ViewBuilder
    private var rootList: some View {
        let items = viewModel.repository.scoreItems
        let favorites = items.favorites(limit: 5)
        let recents = items.mostRecentlyOpened(limit: 5)

        if items.isEmpty && viewModel.repository.tags.isEmpty && viewModel.repository.playlists.isEmpty {
            ContentUnavailableView {
                Label("No Scores Yet", systemImage: "music.note")
            } description: {
                Text("Import your first score to get started.")
            }
        } else {
            List {
                favoritesSection(favorites)
                browseSection(items: items)
                recentsSection(recents)
            }
        }
    }

    @ViewBuilder
    private func favoritesSection(_ favorites: [ScoreItem]) -> some View {
        if !favorites.isEmpty {
            Section("Favorites") {
                ForEach(favorites) { item in
                    ScoreRow(scoreItem: item)
                        .contentShape(Rectangle())
                        .onTapGesture { onOpenScore(item) }
                        .contextMenu { rowContextMenu(for: item) }
                }
            }
        }
    }

    @ViewBuilder
    private func browseSection(items: [ScoreItem]) -> some View {
        Section("Browse") {
            NavigationLink(value: LibraryRoute.allScores) {
                browseRow(title: "All Scores", systemImage: "music.note", count: items.count)
            }
            NavigationLink(value: LibraryRoute.tags) {
                browseRow(title: "Tags", systemImage: "tag", count: viewModel.repository.tags.count)
            }
            NavigationLink(value: LibraryRoute.playlists) {
                browseRow(
                    title: "Playlists",
                    systemImage: "music.note.list",
                    count: viewModel.repository.playlists.count
                )
            }
        }
    }

    @ViewBuilder
    private func recentsSection(_ recents: [ScoreItem]) -> some View {
        if !recents.isEmpty {
            Section("Recently Opened") {
                ForEach(recents) { item in
                    ScoreRow(scoreItem: item)
                        .contentShape(Rectangle())
                        .onTapGesture { onOpenScore(item) }
                        .contextMenu { rowContextMenu(for: item) }
                }
            }
        }
    }

    private func browseRow(title: LocalizedStringResource, systemImage: String, count: Int) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer()
            Text(count, format: .number)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func rowContextMenu(for item: ScoreItem) -> some View {
        Button { onOpenScore(item) } label: {
            Label("Open", systemImage: "music.note")
        }
        Button { Task { await viewModel.toggleFavorite(item) } } label: {
            Label(
                item.isFavorite ? "Unfavorite" : "Favorite",
                systemImage: item.isFavorite ? "star.slash" : "star"
            )
        }
        Button { editTagsTarget = item } label: {
            Label("Edit Tags…", systemImage: "tag")
        }
        Button { addToPlaylistTarget = item } label: {
            Label("Add to Playlist…", systemImage: "music.note.list")
        }
    }

    @ViewBuilder
    private func destination(for route: LibraryRoute) -> some View {
        switch route {
        case .allScores:
            AllScoresContainer(
                library: viewModel,
                onOpen: onOpenScore,
                onEditTags: { editTagsTarget = $0 },
                onAddToPlaylist: { addToPlaylistTarget = $0 }
            )
        case .tags:
            TagsListView(library: viewModel)
        case let .tagDetail(tagID):
            if let tag = viewModel.repository.tags.first(where: { $0.id == tagID }) {
                TagDetailView(
                    tag: tag,
                    library: viewModel,
                    onOpen: onOpenScore,
                    onEditTags: { editTagsTarget = $0 },
                    onAddToPlaylist: { addToPlaylistTarget = $0 },
                    onTagDeleted: { /* NavigationStack pops automatically when destination renders 'Tag not found' */ }
                )
            } else {
                ContentUnavailableView("Tag not found", systemImage: "tag.slash")
            }
        case .playlists:
            PlaylistsListView(library: viewModel)
        case let .playlistDetail(playlistID):
            if let playlist = viewModel.repository.playlists.first(where: { $0.id == playlistID }) {
                PlaylistDetailView(
                    playlist: playlist,
                    library: viewModel,
                    onOpen: onOpenScore,
                    onPlaylistDeleted: { /* same comment as tag */ }
                )
            } else {
                ContentUnavailableView("Playlist not found", systemImage: "music.note.list")
            }
        }
    }

    private var errorAlertBinding: Binding<Bool> {
        Binding(
            get: { viewModel.errorAlertMessage != nil },
            set: { isPresented in if !isPresented { viewModel.errorAlertMessage = nil } }
        )
    }
}

enum ScoreFileTypes {
    /// Content types that the `.fileImporter` accepts. Each is a reasonable
    /// approximation; precise UTType registration is the v1-followup work
    /// (`UTImportedTypeDeclarations` in `App/Info.plist`).
    static var allowed: [UTType] {
        var types: [UTType] = [.xml, .midi]
        // .mscz / .mxl appear as `.zip` to UTType today. Filter post-pick by
        // extension on `prepareImport` (the importer routes by canonical ext).
        types.append(.zip)
        // Plain `.mscx` is XML; explicit `.xml` already covers it.
        return types
    }
}

private struct AllScoresContainer: View {
    let library: LibraryViewModel
    let onOpen: (ScoreItem) -> Void
    let onEditTags: (ScoreItem) -> Void
    let onAddToPlaylist: (ScoreItem) -> Void

    @State private var listVM: ScoreListViewModel

    init(
        library: LibraryViewModel,
        onOpen: @escaping (ScoreItem) -> Void,
        onEditTags: @escaping (ScoreItem) -> Void,
        onAddToPlaylist: @escaping (ScoreItem) -> Void
    ) {
        self.library = library
        self.onOpen = onOpen
        self.onEditTags = onEditTags
        self.onAddToPlaylist = onAddToPlaylist
        _listVM = State(
            wrappedValue: ScoreListViewModel(source: .all, repository: library.repository)
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
        .navigationTitle("All Scores")
    }
}
