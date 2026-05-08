import Domain
import SwiftUI
import UniformTypeIdentifiers
import UtilityUI

@MainActor
public struct LibraryRootScreen<LicenseContent: View, ReaderContent: View, LeadingToolbar: View>: View {
    @Bindable var viewModel: LibraryViewModel
    @Binding private var path: NavigationPath
    private let onOpenScore: (ScoreItem) -> Void
    private let readerDestination: (ScoreItem) -> ReaderContent
    private let licenseContent: () -> LicenseContent
    private let leadingToolbarItem: () -> LeadingToolbar

    @State private var editTagsTarget: ScoreItem?
    @State private var addToPlaylistTarget: ScoreItem?

    public init(
        viewModel: LibraryViewModel,
        path: Binding<NavigationPath>,
        onOpenScore: @escaping (ScoreItem) -> Void,
        @ViewBuilder readerDestination: @escaping (ScoreItem) -> ReaderContent,
        @ViewBuilder licenseContent: @escaping () -> LicenseContent,
        @ViewBuilder leadingToolbarItem: @escaping () -> LeadingToolbar = { EmptyView() }
    ) {
        self.viewModel = viewModel
        _path = path
        self.onOpenScore = onOpenScore
        self.readerDestination = readerDestination
        self.licenseContent = licenseContent
        self.leadingToolbarItem = leadingToolbarItem
    }

    public var body: some View {
        NavigationStack(path: $path) {
            rootList
                .navigationTitle(Text("Library", bundle: .module))
                .toolbar { leadingToolbar }
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
                .navigationDestination(for: ScoreItem.self) { item in
                    readerDestination(item)
                }
        }
        .sheet(item: $editTagsTarget) { item in
            EditTagsScreen(scoreItem: item, library: viewModel)
        }
        .sheet(item: $addToPlaylistTarget) { item in
            AddToPlaylistScreen(scoreItem: item, library: viewModel)
        }
        .alert(
            Text("Library", bundle: .module),
            isPresented: errorAlertBinding,
            presenting: viewModel.errorAlertMessage
        ) { _ in
            Button { viewModel.errorAlertMessage = nil } label: {
                Text("OK", bundle: .module)
            }
        } message: { msg in
            Text(msg)
        }
        .alert(
            Text("Already in Your Library", bundle: .module),
            isPresented: duplicateAlertBinding,
            presenting: viewModel.duplicatePrompt
        ) { prompt in
            Button {
                viewModel.duplicatePrompt = nil
                Task { await viewModel.commit(plan: prompt.plan, decision: .openExisting(prompt.existing.id)) }
            } label: {
                Text("Open", bundle: .module)
            }
            Button {
                viewModel.duplicatePrompt = nil
                Task { await viewModel.commit(plan: prompt.plan, decision: .importAsNew) }
            } label: {
                Text("Import as Duplicate", bundle: .module)
            }
            Button(role: .cancel) {
                viewModel.duplicatePrompt = nil
            } label: {
                Text("Cancel", bundle: .module)
            }
        } message: { prompt in
            Text("\"\(prompt.existing.title)\" is already imported. What do you want to do?", bundle: .module)
        }
        .overlay {
            if viewModel.isPreparingShare {
                ProgressView { Text("Preparing…", bundle: .module) }
                    .padding()
                    .background(.regularMaterial, in: .rect(cornerRadius: 12))
            }
        }
        #if os(iOS)
        .sheet(item: $viewModel.shareTarget) { target in
            ActivityViewControllerRepresentable(items: target.urls)
        }
        #endif
    }

    @ToolbarContentBuilder
    private var importToolbar: some ToolbarContent {
        #if os(iOS)
            ToolbarItem(placement: .topBarTrailing) { importButton }
        #else
            ToolbarItem(placement: .automatic) { importButton }
        #endif
    }

    @ToolbarContentBuilder
    private var leadingToolbar: some ToolbarContent {
        #if os(iOS)
            ToolbarItem(placement: .topBarLeading) { leadingToolbarItem() }
        #else
            ToolbarItem(placement: .automatic) { leadingToolbarItem() }
        #endif
    }

    private var importButton: some View {
        Button {
            viewModel.isFileImporterPresented = true
        } label: {
            Image(systemName: "plus").accessibilityLabel(Text("Import Score", bundle: .module))
        }
    }

    @ViewBuilder
    private var rootList: some View {
        let items = viewModel.repository.scoreItems
        let recents = items.mostRecentlyOpened(limit: 5)

        if items.isEmpty && viewModel.repository.tags.isEmpty && viewModel.repository.playlists.isEmpty {
            ContentUnavailableView {
                Label {
                    Text("No Scores Yet", bundle: .module)
                } icon: {
                    Image(systemName: "music.note")
                }
            } description: {
                Text("Import your first score to get started.", bundle: .module)
            }
        } else {
            List {
                browseSection(items: items)
                // Tasks 6 + 7 will insert playlistsSection / tagsSection here.
                recentsSection(recents)
            }
        }
    }

    @ViewBuilder
    private func browseSection(items: [ScoreItem]) -> some View {
        let favoriteCount = items.filter(\.isFavorite).count
        Section {
            NavigationLink(value: LibraryRoute.allScores) {
                browseRow(title: "All Scores", systemImage: "music.note", count: items.count)
            }
            if favoriteCount > 0 {
                NavigationLink(value: LibraryRoute.favorites) {
                    browseRow(title: "Favorites", systemImage: "heart.fill", count: favoriteCount)
                }
            }
        } header: {
            Text("Browse", bundle: .module)
        }
    }

    @ViewBuilder
    private func recentsSection(_ recents: [ScoreItem]) -> some View {
        if !recents.isEmpty {
            Section {
                ForEach(recents) { item in
                    sectionRow(for: item)
                }
            } header: {
                Text("Recently Opened", bundle: .module)
            }
        }
    }

    @ViewBuilder
    private func sectionRow(for item: ScoreItem) -> some View {
        HStack(spacing: 0) {
            ScoreRow(scoreItem: item)
                .contentShape(Rectangle())
                .onTapGesture { onOpenScore(item) }
            Menu {
                scoreRowMenu(
                    item: item,
                    library: viewModel,
                    onOpen: onOpenScore,
                    onEditTags: { editTagsTarget = $0 },
                    onAddToPlaylist: { addToPlaylistTarget = $0 },
                    onRequestDelete: nil
                )
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("More", bundle: .module))
        }
        .contextMenu {
            scoreRowMenu(
                item: item,
                library: viewModel,
                onOpen: onOpenScore,
                onEditTags: { editTagsTarget = $0 },
                onAddToPlaylist: { addToPlaylistTarget = $0 },
                onRequestDelete: nil
            )
        }
    }

    private func browseRow(title: LocalizedStringKey, systemImage: String, count: Int) -> some View {
        HStack {
            Label {
                Text(title, bundle: .module)
            } icon: {
                Image(systemName: systemImage)
            }
            Spacer()
            Text(count, format: .number)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func destination(for route: LibraryRoute) -> some View {
        switch route {
        case .allScores:
            AllScoresScreen(
                library: viewModel,
                onOpen: onOpenScore,
                onEditTags: { editTagsTarget = $0 },
                onAddToPlaylist: { addToPlaylistTarget = $0 }
            )
        case .favorites:
            FavoritesScreen(
                library: viewModel,
                onOpen: onOpenScore,
                onEditTags: { editTagsTarget = $0 },
                onAddToPlaylist: { addToPlaylistTarget = $0 }
            )
        case .tags:
            TagsListScreen(library: viewModel)
        case let .tagDetail(tagID):
            if let tag = viewModel.repository.tags.first(where: { $0.id == tagID }) {
                TagDetailScreen(
                    tag: tag,
                    library: viewModel,
                    onOpen: onOpenScore,
                    onEditTags: { editTagsTarget = $0 },
                    onAddToPlaylist: { addToPlaylistTarget = $0 },
                    onTagDeleted: { /* NavigationStack pops automatically when destination renders 'Tag not found' */ }
                )
            } else {
                ContentUnavailableView {
                    Label {
                        Text("Tag not found", bundle: .module)
                    } icon: {
                        Image(systemName: "tag.slash")
                    }
                }
            }
        case .playlists:
            PlaylistsListScreen(library: viewModel)
        case let .playlistDetail(playlistID):
            if let playlist = viewModel.repository.playlists.first(where: { $0.id == playlistID }) {
                PlaylistDetailScreen(
                    playlist: playlist,
                    library: viewModel,
                    onOpen: onOpenScore,
                    onPlaylistDeleted: { /* same comment as tag */ }
                )
            } else {
                ContentUnavailableView {
                    Label {
                        Text("Playlist not found", bundle: .module)
                    } icon: {
                        Image(systemName: "music.note.list")
                    }
                }
            }
        }
    }

    private var errorAlertBinding: Binding<Bool> {
        Binding(
            get: { viewModel.errorAlertMessage != nil },
            set: { isPresented in if !isPresented { viewModel.errorAlertMessage = nil } }
        )
    }

    private var duplicateAlertBinding: Binding<Bool> {
        Binding(
            get: { viewModel.duplicatePrompt != nil },
            set: { isPresented in if !isPresented { viewModel.duplicatePrompt = nil } }
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

private struct AllScoresScreen: View {
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
        ScoreListScreen(
            viewModel: listVM,
            library: library,
            onOpen: onOpen,
            onEditTags: onEditTags,
            onAddToPlaylist: onAddToPlaylist
        )
        .navigationTitle(Text("All Scores", bundle: .module))
    }
}
